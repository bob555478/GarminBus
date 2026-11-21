import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Time;
import Toybox.Timer;
import Toybox.Position;

class BusTimesView extends WatchUi.View {

    private var _stations as Array<Station> = [];
    // _page_index: 0..(_stations.size()-1) are stations; _stations.size() is the "Scan Nearby Stations (GPS)" card
    private var _page_index as Number = 0;
    private var _refreshTimer as Timer.Timer?;
    private var _lastWidth as Number = 260;
    private var _lastHeight as Number = 260;
    private var _hasUserCoords as Boolean = false;
    private var _userLat as Float = 32.0628f;
    private var _userLon as Float = 34.7905f;
    private var _hasAutoSelectedClosest as Boolean = false;

    // Line selection mode: after clicking SELECT on a station, UP/DOWN scrolls arriving lines
    private var _isSelectingLine as Boolean = false;
    private var _selectedBusIndex as Number = 0;
    private var _busScrollOffset as Number = 0;

    // Spread-out request scheduler state (min 6s spacing between any two station requests)
    private var _lastGlobalRequestEpoch as Number = 0;

    public function initialize() {
        View.initialize();
        reloadFavoritesList();
    }

    public function onShow() as Void {
        if (_refreshTimer == null) {
            _refreshTimer = new Timer.Timer();
            // 5s tick drives smooth local ETA countdowns + staggered adaptive refreshes
            _refreshTimer.start(method(:onAutoRefreshTick), 5000, true);
        }
        updateUserLocationAndSortFavorites();
    }

    public function onHide() as Void {
        if (_refreshTimer != null) {
            _refreshTimer.stop();
            _refreshTimer = null;
        }
    }

    public function updateUserLocationAndSortFavorites() as Void {
        var info = Position.getInfo();
        if (info != null && info.position != null && info.accuracy != Position.QUALITY_NOT_AVAILABLE) {
            var coords = info.position.toDegrees();
            if (coords != null && coords.size() >= 2) {
                var lat = coords[0].toFloat();
                var lon = coords[1].toFloat();
                if (lat > 29.0f && lat < 34.0f && lon > 34.0f && lon < 36.0f) {
                    _userLat = lat;
                    _userLon = lon;
                    _hasUserCoords = true;
                    sortStationsByDistance(true);
                    return;
                }
            }
        }
        // Request a background one-shot GPS fix to sort favorites by distance once acquired
        if (_stations.size() > 1) {
            Position.enableLocationEvents(Position.LOCATION_ONE_SHOT, method(:onFavoritesPositionFix));
        }
    }

    public function onFavoritesPositionFix(info as Position.Info) as Void {
        if (info != null && info.position != null) {
            var coords = info.position.toDegrees();
            if (coords != null && coords.size() >= 2) {
                var lat = coords[0].toFloat();
                var lon = coords[1].toFloat();
                if (lat > 29.0f && lat < 34.0f && lon > 34.0f && lon < 36.0f) {
                    _userLat = lat;
                    _userLon = lon;
                    _hasUserCoords = true;
                    sortStationsByDistance(!_hasAutoSelectedClosest);
                    _hasAutoSelectedClosest = true;
                    WatchUi.requestUpdate();
                }
            }
        }
    }

    public function setKnownUserLocation(lat as Float, lon as Float) as Void {
        _userLat = lat;
        _userLon = lon;
        _hasUserCoords = true;
        sortStationsByDistance(false);
    }

    public function sortStationsByDistance(jumpToClosest as Boolean) as Void {
        if (!_hasUserCoords || _stations.size() == 0) {
            return;
        }

        var currentStation = getCurrentStation();
        var currentCode = (currentStation != null) ? currentStation.getStationCode() : null;
        var wasOnNearby = isOnNearbyCard();

        // Update distances for all stations
        for (var i = 0; i < _stations.size(); i++) {
            var st = _stations[i];
            var dist = Utils.calculateDistanceMeters(_userLat, _userLon, st.getLat(), st.getLon());
            st.setDistanceMeters(dist);
        }

        // Bubble sort ascending by distance
        for (var i = 0; i < _stations.size(); i++) {
            for (var j = 0; j < _stations.size() - i - 1; j++) {
                var d1 = _stations[j].getDistanceMeters();
                var d2 = _stations[j + 1].getDistanceMeters();
                if (d1 < 0) {
                    d1 = 9999999;
                }
                if (d2 < 0) {
                    d2 = 9999999;
                }
                if (d1 > d2) {
                    var tmp = _stations[j];
                    _stations[j] = _stations[j + 1];
                    _stations[j + 1] = tmp;
                }
            }
        }

        if (wasOnNearby) {
            _page_index = _stations.size();
        } else if (jumpToClosest && !_hasAutoSelectedClosest) {
            _page_index = 0;
            _hasAutoSelectedClosest = true;
        } else if (currentCode != null) {
            for (var i = 0; i < _stations.size(); i++) {
                if (currentCode.equals(_stations[i].getStationCode())) {
                    _page_index = i;
                    break;
                }
            }
        }
    }

    public function onAutoRefreshTick() as Void {
        var now = Time.now().value();
        var current = getCurrentStation();

        // 1. Update local ETA countdowns & GPS update ages on the visible station (no network call)
        if (current != null) {
            current.tickCountdowns();
            WatchUi.requestUpdate();
        }

        // 2. Spread out network requests: never send if any station is already loading or < 6s since last request
        if ((now - _lastGlobalRequestEpoch) < 6) {
            return;
        }
        for (var i = 0; i < _stations.size(); i++) {
            if (_stations[i].isLoading()) {
                return;
            }
        }

        // 3. Priority 1: Current visible station
        //    - If a bus line is currently selected, refresh every 15s
        //    - Otherwise use its adaptive interval (min 45s, scaling up with ETA)
        if (current != null) {
            var dueNow = false;
            if (_isSelectingLine) {
                dueNow = ((now - current.getLastFetchEpoch()) >= 15);
            } else {
                dueNow = (now >= current.getNextRefreshEpoch());
            }
            if (dueNow) {
                _lastGlobalRequestEpoch = now;
                current.update_station_buses();
                return;
            }
        }

        // 4. Priority 2: Background favorite stations — refresh at most ONE most-overdue station per tick
        var bestStation = null as Station?;
        var mostOverdue = 0;
        for (var i = 0; i < _stations.size(); i++) {
            var st = _stations[i];
            if (st == current) {
                continue;
            }
            var nextEpoch = st.getNextRefreshEpoch();
            if (now >= nextEpoch) {
                var overdue = now - nextEpoch;
                if (bestStation == null || overdue > mostOverdue) {
                    bestStation = st;
                    mostOverdue = overdue;
                }
            }
        }

        if (bestStation != null) {
            _lastGlobalRequestEpoch = now;
            bestStation.update_station_buses();
        }
    }

    public function reloadFavoritesList() as Void {
        FavoritesStorage.syncPhoneNicknames(null);
        var favDicts = FavoritesStorage.loadFavorites();
        _stations = [];
        var now = Time.now().value();

        for (var i = 0; i < favDicts.size(); i++) {
            var d = favDicts[i];
            var name = Utils.toStringSafe(d["name"], "Station");
            var code = Utils.toStringSafe(d["code"], "");
            if (code.length() == 0) {
                continue;
            }
            var st = new Station(name, code, [], api_requester);
            var nick = Utils.toStringSafe(d["nickname"], "");
            if (nick.length() > 0) {
                st.setNickname(nick);
            }
            var lat = Utils.toFloatSafe(d["lat"]);
            var lon = Utils.toFloatSafe(d["lon"]);
            if (lat != null && lon != null) {
                st.setCoordinates(lat, lon);
            }
            // Stagger initial station refreshes so they don't all fire at once
            st.setNextRefreshEpoch(now + ((i + 1) * 7));
            _stations.add(st);
        }

        if (_hasUserCoords) {
            sortStationsByDistance(true);
        }

        if (_page_index > _stations.size()) {
            _page_index = 0;
        }

        // Fetch ONLY the active station right away; others follow staggered every ~7s
        var active = getCurrentStation();
        if (active != null) {
            _lastGlobalRequestEpoch = now;
            active.update_station_buses();
        }
        WatchUi.requestUpdate();
    }

    public function applyNicknameToStation(stationCode as String, nickname as String) as Void {
        for (var i = 0; i < _stations.size(); i++) {
            if (stationCode.equals(_stations[i].getStationCode())) {
                _stations[i].setNickname(nickname);
            }
        }
        WatchUi.requestUpdate();
    }

    // Open a station selected from Nearby GPS scan in the carousel immediately
    public function openPreviewStation(station as Station) as Void {
        for (var i = 0; i < _stations.size(); i++) {
            if (station.getStationCode().equals(_stations[i].getStationCode())) {
                _page_index = i;
                _stations[i].update_station_buses();
                WatchUi.requestUpdate();
                return;
            }
        }
        _stations.add(station);
        _page_index = _stations.size() - 1;
        WatchUi.requestUpdate();
    }

    public function isOnNearbyCard() as Boolean {
        return (_page_index == _stations.size());
    }

    public function getCurrentStation() as Station? {
        if (_page_index >= 0 && _page_index < _stations.size()) {
            return _stations[_page_index];
        }
        return null;
    }

    public function isSelectingLine() as Boolean {
        return _isSelectingLine;
    }

    public function enterLineSelection() as Boolean {
        var station = getCurrentStation();
        if (station == null) {
            return false;
        }
        var buses = station.getBuses();
        if (buses.size() == 0) {
            return false;
        }
        _isSelectingLine = true;
        _selectedBusIndex = 0;
        _busScrollOffset = 0;
        WatchUi.requestUpdate();
        return true;
    }

    public function exitLineSelection() as Void {
        if (_isSelectingLine) {
            _isSelectingLine = false;
            _selectedBusIndex = 0;
            _busScrollOffset = 0;
            WatchUi.requestUpdate();
        }
    }

    public function moveBusSelection(delta as Number) as Void {
        var station = getCurrentStation();
        if (station == null) {
            return;
        }
        var buses = station.getBuses();
        var total = buses.size();
        if (total == 0) {
            return;
        }

        _selectedBusIndex += delta;
        if (_selectedBusIndex < 0) {
            _selectedBusIndex = total - 1;
        } else if (_selectedBusIndex >= total) {
            _selectedBusIndex = 0;
        }

        // Keep selected row visible within the 4-row window
        if (_selectedBusIndex < _busScrollOffset) {
            _busScrollOffset = _selectedBusIndex;
        } else if (_selectedBusIndex >= _busScrollOffset + 4) {
            _busScrollOffset = _selectedBusIndex - 3;
        }

        WatchUi.requestUpdate();
    }

    public function getSelectedBus() as Dictionary? {
        var station = getCurrentStation();
        if (station == null) {
            return null;
        }
        var buses = station.getBuses();
        if (_selectedBusIndex >= 0 && _selectedBusIndex < buses.size()) {
            return buses[_selectedBusIndex];
        }
        return null;
    }

    // Hit-test a tap coordinate against the displayed bus rows (returns bus index or -1)
    public function getBusIndexAtPoint(clickX as Number, clickY as Number) as Number {
        var station = getCurrentStation();
        if (station == null) {
            return -1;
        }
        var buses = station.getBuses();
        var total = buses.size();
        if (total == 0) {
            return -1;
        }
        var visibleCount = total - _busScrollOffset;
        if (visibleCount > 4) {
            visibleCount = 4;
        }

        if (clickX < (_lastWidth * 0.10).toNumber() || clickX > (_lastWidth * 0.95).toNumber()) {
            return -1;
        }
        var startY = (_lastHeight * 0.29).toNumber();
        var rowHeight = (_lastHeight * 0.14).toNumber();
        if (clickY < startY || clickY >= startY + (visibleCount * rowHeight)) {
            return -1;
        }
        var row = ((clickY - startY) / rowHeight).toNumber();
        var idx = _busScrollOffset + row;
        if (idx >= 0 && idx < total) {
            return idx;
        }
        return -1;
    }

    public function switchPage(is_forward as Boolean) as Void {
        _isSelectingLine = false;
        _selectedBusIndex = 0;
        _busScrollOffset = 0;
        var totalPages = _stations.size() + 1;
        if (is_forward) {
            _page_index++;
            if (_page_index >= totalPages) {
                _page_index = 0;
            }
        } else {
            _page_index--;
            if (_page_index < 0) {
                _page_index = totalPages - 1;
            }
        }

        var st = getCurrentStation();
        if (st != null && st.getBuses().size() == 0 && !st.isLoading()) {
            st.update_station_buses();
        }
        WatchUi.requestUpdate();
    }

    public function refreshCurrentStation() as Void {
        var st = getCurrentStation();
        if (st != null) {
            st.update_station_buses();
        }
    }

    public function toggleCurrentFavorite() as Void {
        var st = getCurrentStation();
        if (st == null) {
            return;
        }
        var isNowFav = FavoritesStorage.toggleFavorite(st);
        if (isNowFav) {
            sortStationsByDistance(false);
        } else {
            // Remove station from the active carousel list if unfavorited
            var code = st.getStationCode();
            var updated = [] as Array<Station>;
            for (var i = 0; i < _stations.size(); i++) {
                if (!code.equals(_stations[i].getStationCode())) {
                    updated.add(_stations[i]);
                }
            }
            _stations = updated;
            if (_page_index > _stations.size()) {
                _page_index = _stations.size();
            }
        }
        WatchUi.requestUpdate();
    }

    public function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var width = dc.getWidth();
        var height = dc.getHeight();
        _lastWidth = width;
        _lastHeight = height;

        if (isOnNearbyCard()) {
            drawNearbyScanCard(dc, width, height);
        } else {
            var station = getCurrentStation();
            if (station != null) {
                drawStationHeader(dc, width, height, station);
                drawStationBuses(dc, width, height, station);
            }
        }

        drawPageIndicators(dc, width, height);
    }

    private function drawNearbyScanCard(dc as Dc, w as Number, h as Number) as Void {
        // Header
        dc.setColor(0x00AAFF, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            (h * 0.10).toNumber(),
            Graphics.FONT_SMALL,
            "Station Map",
            Graphics.TEXT_JUSTIFY_CENTER
        );

        // Central Radar/Map Preview Graphic with Station Icons
        var cx = w / 2;
        var cy = (h * 0.46).toNumber();
        var r = (w * 0.22).toNumber();

        dc.setColor(0x0D2130, 0x0D2130);
        dc.fillCircle(cx, cy, r);
        dc.setColor(0x1E3F5A, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cx - r, cy, cx + r, cy);
        dc.drawLine(cx, cy - r, cx, cy + r);
        dc.setColor(0x00AAFF, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawCircle(cx, cy, r);
        dc.drawCircle(cx, cy, (r * 0.55).toNumber());
        dc.setPenWidth(1);

        // Center User GPS dot
        dc.setColor(0x00E5FF, 0x00E5FF);
        dc.fillCircle(cx, cy, 4);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(cx, cy, 5);

        // Mini bus station pin icons around center
        var p1x = cx + (r * 0.45).toNumber();
        var p1y = cy - (r * 0.35).toNumber();
        dc.setColor(0x00FF66, 0x00FF66);
        dc.fillRoundedRectangle(p1x - 5, p1y - 5, 10, 10, 2);

        var p2x = cx - (r * 0.48).toNumber();
        var p2y = cy + (r * 0.28).toNumber();
        dc.setColor(0xFFCC00, 0xFFCC00);
        dc.fillRoundedRectangle(p2x - 5, p2y - 5, 10, 10, 2);

        var p3x = cx + (r * 0.20).toNumber();
        var p3y = cy + (r * 0.52).toNumber();
        dc.setColor(0x00AAFF, 0x00AAFF);
        dc.fillRoundedRectangle(p3x - 4, p3y - 4, 8, 8, 2);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            (h * 0.72).toNumber(),
            Graphics.FONT_SMALL,
            "Nearby Map",
            Graphics.TEXT_JUSTIFY_CENTER
        );

        dc.setColor(0x00FF66, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            (h * 0.84).toNumber(),
            Graphics.FONT_XTINY,
            "Press SELECT for Map",
            Graphics.TEXT_JUSTIFY_CENTER
        );
    }

    private function drawStationHeader(dc as Dc, w as Number, h as Number, station as Station) as Void {
        var code = station.getStationCode();
        var isFav = FavoritesStorage.isFavorite(code);

        // Top line: Favorite marker + Stop Code + Distance (if known)
        var dist = station.getDistanceMeters();
        var distStr = "";
        if (dist >= 0) {
            if (dist >= 1000) {
                distStr = " (" + (dist / 1000.0f).format("%.1f") + "km)";
            } else {
                distStr = " (" + dist.toString() + "m)";
            }
        }
        var topBadge = (isFav ? "[FAV] " : "") + "#" + code + distStr;
        dc.setColor(isFav ? 0xFFCC00 : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            (h * 0.05).toNumber(),
            Graphics.FONT_XTINY,
            topBadge,
            Graphics.TEXT_JUSTIFY_CENTER
        );

        // Station Name or Nickname (guaranteed ASCII-safe)
        var name = station.getDisplayName();
        if (name.length() > 18) {
            name = name.substring(0, 16) + "..";
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            (h * 0.14).toNumber(),
            Graphics.FONT_SMALL,
            name,
            Graphics.TEXT_JUSTIFY_CENTER
        );

        // Subtle divider line
        dc.setColor(0x334455, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(
            (w * 0.14).toNumber(),
            (h * 0.26).toNumber(),
            (w * 0.86).toNumber(),
            (h * 0.26).toNumber()
        );
    }

    private function drawStationBuses(dc as Dc, w as Number, h as Number, station as Station) as Void {
        var buses = station.getBuses();

        if (station.isLoading() && buses.size() == 0) {
            dc.setColor(0x00AAFF, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                w / 2,
                (h * 0.50).toNumber(),
                Graphics.FONT_SMALL,
                "Loading arrivals...",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
            return;
        }

        var errMsg = station.getErrorMsg();
        if (errMsg != null && buses.size() == 0) {
            dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                w / 2,
                (h * 0.45).toNumber(),
                Graphics.FONT_XTINY,
                errMsg,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                w / 2,
                (h * 0.60).toNumber(),
                Graphics.FONT_XTINY,
                "Press SELECT for Menu",
                Graphics.TEXT_JUSTIFY_CENTER
            );
            return;
        }

        if (buses.size() == 0) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                w / 2,
                (h * 0.50).toNumber(),
                Graphics.FONT_SMALL,
                "No upcoming buses",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
            return;
        }

        // Draw up to 4 bus rows cleanly fitted inside the round watch screen
        var maxRows = 4;
        var startY = (h * 0.29).toNumber();
        var rowHeight = (h * 0.14).toNumber();

        if (_busScrollOffset >= buses.size()) {
            _busScrollOffset = 0;
        }
        if (_selectedBusIndex >= buses.size()) {
            _selectedBusIndex = 0;
        }

        for (var row = 0; row < maxRows && (_busScrollOffset + row) < buses.size(); row++) {
            var idx = _busScrollOffset + row;
            var bus = buses[idx];
            var routeNum = Utils.toStringSafe(bus["route"], "?");
            var etaLabel = Utils.toStringSafe(bus["eta_label"], "--");
            var operatorId = Utils.toStringSafe(bus["operator_id"], "");
            var status = bus["status"] as Number;
            var isLive = (bus["is_live"] == true);
            var isSelectedRow = (_isSelectingLine && idx == _selectedBusIndex);

            var rowTopY = startY + (row * rowHeight);
            var rowCenterY = rowTopY + (rowHeight / 2);

            // Card row background (Bus Nearby dark card aesthetic)
            var cardX = (w * 0.11).toNumber();
            var cardW = (w * 0.81).toNumber();
            if (isSelectedRow) {
                dc.setColor(0x163854, 0x163854);
                dc.fillRoundedRectangle(cardX, rowTopY + 1, cardW, rowHeight - 2, 7);
                dc.setColor(0x00E5FF, Graphics.COLOR_TRANSPARENT);
                dc.drawRoundedRectangle(cardX, rowTopY + 1, cardW, rowHeight - 2, 7);
            } else {
                dc.setColor(0x0D1A26, 0x0D1A26);
                dc.fillRoundedRectangle(cardX, rowTopY + 2, cardW, rowHeight - 4, 6);
            }

            // Bus Nearby style arrival time colors:
            // - Vibrant Emerald Green (0x00FF55): Live real-time GPS tracking & on-route
            // - Slate Gray (0xAAAAAA): Scheduled timetable only (no live GPS)
            // - Warm Amber/Orange (0xFFAA00): Delayed / moderate time since last GPS update
            // - Coral Red (0xFF3333): Off-route or stale GPS feed
            var timeColor = 0xAAAAAA;
            if (status == Utils.STATUS_LIVE_ON_ROUTE) {
                timeColor = 0x00FF55;
            } else if (status == Utils.STATUS_STALE_WARN) {
                timeColor = 0xFFAA00;
            } else if (status == Utils.STATUS_STALE_OR_OFF) {
                timeColor = 0xFF3333;
            }

            // Left side: Bus Nearby Agency-Colored Filled Route Pill (Dan Blue, Egged Green, Metropoline Orange, etc.)
            var pillX = (w * 0.14).toNumber();
            var pillW = (w * 0.25).toNumber();
            var pillH = (rowHeight * 0.78).toNumber();
            var pillY = rowCenterY - (pillH / 2);

            var badgeBgColor = getOperatorBrandColor(operatorId);
            dc.setColor(badgeBgColor, badgeBgColor);
            dc.fillRoundedRectangle(pillX, pillY, pillW, pillH, 6);
            dc.setColor(0xFFFFFF, Graphics.COLOR_TRANSPARENT);
            dc.drawRoundedRectangle(pillX, pillY, pillW, pillH, 6);

            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                pillX + (pillW / 2),
                rowCenterY,
                Graphics.FONT_SMALL,
                routeNum,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );

            // Center: Bus Nearby style Live Signal Waves icon ())) when live, or clock dot when scheduled
            var waveX = (w * 0.42).toNumber();
            drawBusNearbySignalIcon(dc, waveX, rowCenterY, timeColor, isLive);

            // Right side: Nearest bus time (large/bold) followed in small by the next bus afterwards time
            var nextEtaLabel = Utils.toStringSafe(bus["next_eta_label"], "");
            if (nextEtaLabel.length() > 0) {
                var nextStatusObj = bus["next_status"];
                var nextColor = 0x99AABB;
                if (nextStatusObj != null && nextStatusObj instanceof Lang.Number) {
                    var ns = nextStatusObj as Number;
                    if (ns == Utils.STATUS_LIVE_ON_ROUTE) {
                        nextColor = 0x55CC88;
                    } else if (ns == Utils.STATUS_STALE_WARN) {
                        nextColor = 0xCC8833;
                    } else if (ns == Utils.STATUS_STALE_OR_OFF) {
                        nextColor = 0xCC4444;
                    }
                }

                var smallText = "," + nextEtaLabel;
                var smallWidth = dc.getTextWidthInPixels(smallText, Graphics.FONT_XTINY);
                var rightEdgeX = (w * 0.85).toNumber();

                // Draw the following bus time in small font on the right
                dc.setColor(nextColor, Graphics.COLOR_TRANSPARENT);
                dc.drawText(
                    rightEdgeX,
                    rowCenterY + 1,
                    Graphics.FONT_XTINY,
                    smallText,
                    Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER
                );

                // Draw the nearest bus arrival time in large font immediately before it
                dc.setColor(timeColor, Graphics.COLOR_TRANSPARENT);
                dc.drawText(
                    rightEdgeX - smallWidth - 2,
                    rowCenterY,
                    Graphics.FONT_SMALL,
                    etaLabel,
                    Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER
                );
            } else {
                dc.setColor(timeColor, Graphics.COLOR_TRANSPARENT);
                dc.drawText(
                    (w * 0.85).toNumber(),
                    rowCenterY,
                    Graphics.FONT_SMALL,
                    etaLabel,
                    Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER
                );
            }

            // Chevron hint indicating row opens live route map
            var chevX = (w * 0.87).toNumber();
            dc.setColor(isSelectedRow ? 0x00FF66 : 0x557799, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(isSelectedRow ? 2 : 1);
            dc.drawLine(chevX, rowCenterY - 4, chevX + 4, rowCenterY);
            dc.drawLine(chevX + 4, rowCenterY, chevX, rowCenterY + 4);
            dc.setPenWidth(1);
        }

        if (_isSelectingLine) {
            var selBus = getSelectedBus();
            var hint = "SEL: Map (" + (_selectedBusIndex + 1).toString() + "/" + buses.size().toString() + ")";
            if (selBus != null) {
                var pObj = selBus["ping_local_epoch"];
                if (pObj != null && pObj instanceof Lang.Number) {
                    var ageStr = Utils.formatAgeShort(Time.now().value() - (pObj as Number));
                    hint = "GPS " + ageStr + " ago | SEL";
                } else {
                    hint = "Scheduled | SEL";
                }
            }
            dc.setColor(0x00CCFF, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, (h * 0.88).toNumber(), Graphics.FONT_XTINY, hint, Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            drawColorLegend(dc, w, h, station.isLoading());
        }
    }

    // Returns the Israeli transit operator brand color for the route number pill (matching Bus Nearby)
    private function getOperatorBrandColor(operatorId as String) as Number {
        if ("3".equals(operatorId)) {
            return 0x007A33; // Egged: Deep Forest Green
        } else if ("5".equals(operatorId)) {
            return 0x0055CC; // Dan: Royal Blue
        } else if ("15".equals(operatorId)) {
            return 0xCC5500; // Metropoline: Deep Orange
        } else if ("16".equals(operatorId)) {
            return 0x007788; // Superbus: Teal
        } else if ("18".equals(operatorId)) {
            return 0x0066AA; // Kavim: Navy/Cobalt Blue
        } else if ("25".equals(operatorId)) {
            return 0x882288; // Afikim / Electra: Purple
        } else if ("31".equals(operatorId) || "32".equals(operatorId)) {
            return 0x227755; // Dan BaDarom / Dan Beer Sheva: Sea Green
        }
        return 0x1E4D8C; // Default Transit Blue pill
    }

    // Draws the signature Bus Nearby real-time wireless signal arcs (or subtle schedule dot) next to the arrival time
    private function drawBusNearbySignalIcon(
        dc as Dc,
        x as Number,
        y as Number,
        color as Number,
        isLive as Boolean
    ) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        if (isLive) {
            // Live origin dot + two radiating signal wave arcs facing the arrival time
            dc.fillCircle(x, y, 2);
            dc.drawArc(x, y, 5, Graphics.ARC_COUNTER_CLOCKWISE, 315, 45);
            dc.drawArc(x, y, 8, Graphics.ARC_COUNTER_CLOCKWISE, 315, 45);
        } else {
            // Scheduled only: hollow small clock ring
            dc.drawCircle(x + 3, y, 3);
        }
    }

    private function drawColorLegend(dc as Dc, w as Number, h as Number, isRefreshing as Boolean) as Void {
        var y = (h * 0.88).toNumber();
        if (isRefreshing) {
            dc.setColor(0x00AAFF, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, y, Graphics.FONT_XTINY, "Refreshing...", Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        // Compact 4-color dot indicator at bottom of screen
        var cy = (h * 0.92).toNumber();
        var spacing = 14;
        var startX = (w / 2) - (spacing * 3 / 2);

        dc.setColor(0x00FF55, 0x00FF55);
        dc.fillCircle(startX, cy, 3);

        dc.setColor(0xAAAAAA, 0xAAAAAA);
        dc.fillCircle(startX + spacing, cy, 3);

        dc.setColor(0xFFAA00, 0xFFAA00);
        dc.fillCircle(startX + (spacing * 2), cy, 3);

        dc.setColor(0xFF3333, 0xFF3333);
        dc.fillCircle(startX + (spacing * 3), cy, 3);
    }

    private function drawPageIndicators(dc as Dc, w as Number, h as Number) as Void {
        var totalPages = _stations.size() + 1;
        if (totalPages <= 1) {
            return;
        }

        var dotSpacing = 12;
        var totalHeight = (totalPages - 1) * dotSpacing;
        var startY = (h / 2) - (totalHeight / 2);
        var x = (w * 0.06).toNumber();

        for (var i = 0; i < totalPages; i++) {
            var y = startY + (i * dotSpacing);
            if (i == _page_index) {
                var color = (i == _stations.size()) ? 0x00AAFF : Graphics.COLOR_WHITE;
                dc.setColor(color, color);
                dc.fillCircle(x, y, 4);
            } else {
                dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_DK_GRAY);
                dc.fillCircle(x, y, 2);
            }
        }
    }
}
