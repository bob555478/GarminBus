import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Position;
import Toybox.Math;

class NearbyStationsView extends WatchUi.View {

    private static const MIN_ZOOM = 12;
    private static const MAX_ZOOM = 17;

    private var _parentView as BusTimesView;
    private var _nearbyStations as Array<Station> = [];
    private var _selectedIndex as Number = 0;
    private var _isScanningGps as Boolean = true;
    private var _isFetchingApi as Boolean = false;
    private var _statusMessage as String = "Locating GPS...";
    private var _userLat as Float = 32.0628f;
    private var _userLon as Float = 34.7905f;

    // Map zoom & road tile manager
    private var _tileManager as MapTileManager;
    private var _zoom as Number = 15;
    private var _zoomMode as Boolean = false;
    private var _screenW as Number = 260;
    private var _screenH as Number = 260;

    // Cache last computed screen coordinates of stations for tap selection on touchscreens
    private var _stationScreenX as Array<Number> = [];
    private var _stationScreenY as Array<Number> = [];

    public function initialize(parentView as BusTimesView) {
        View.initialize();
        _parentView = parentView;
        _tileManager = new MapTileManager();
    }

    public function onLayout(dc as Dc) as Void {
        _screenW = dc.getWidth();
        _screenH = dc.getHeight();
    }

    public function onShow() as Void {
        if (_nearbyStations.size() == 0 && !_isFetchingApi) {
            startGpsSearch();
        } else if (_nearbyStations.size() > 0) {
            requestRoadTiles();
        }
    }

    public function onHide() as Void {
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
        _tileManager.clear();
    }

    private function computeTileSize() as Number {
        var sz = (_screenW * 0.62).toNumber();
        if (sz < 128) {
            sz = 128;
        } else if (sz > 180) {
            sz = 180;
        }
        return sz;
    }

    private function requestRoadTiles() as Void {
        _tileManager.updateForCenter(_userLat, _userLon, _zoom, computeTileSize());
    }

    public function isZoomMode() as Boolean {
        return _zoomMode;
    }

    public function toggleZoomMode() as Void {
        _zoomMode = !_zoomMode;
        WatchUi.requestUpdate();
    }

    public function exitZoomMode() as Void {
        if (_zoomMode) {
            _zoomMode = false;
            WatchUi.requestUpdate();
        }
    }

    public function zoomIn() as Void {
        if (_zoom < MAX_ZOOM) {
            _zoom++;
            requestRoadTiles();
            WatchUi.requestUpdate();
        }
    }

    public function zoomOut() as Void {
        if (_zoom > MIN_ZOOM) {
            _zoom--;
            requestRoadTiles();
            WatchUi.requestUpdate();
        }
    }

    public function startGpsSearch() as Void {
        _isScanningGps = true;
        _isFetchingApi = false;
        _statusMessage = "Locating GPS...";
        WatchUi.requestUpdate();

        // Check if watch already has a recent last-known position
        var info = Position.getInfo();
        if (info != null && info.position != null && info.accuracy != Position.QUALITY_NOT_AVAILABLE) {
            var coords = info.position.toDegrees();
            if (coords != null && coords.size() >= 2) {
                var lat = coords[0].toFloat();
                var lon = coords[1].toFloat();
                if (lat > 29.0f && lat < 34.0f && lon > 34.0f && lon < 36.0f) {
                    _userLat = lat;
                    _userLon = lon;
                    fetchStationsForCoords(_userLat, _userLon);
                    return;
                }
            }
        }

        // Request active one-shot GPS fix
        Position.enableLocationEvents(Position.LOCATION_ONE_SHOT, method(:onPosition));
    }

    public function onPosition(info as Position.Info) as Void {
        if (info != null && info.position != null) {
            var coords = info.position.toDegrees();
            if (coords != null && coords.size() >= 2) {
                var lat = coords[0].toFloat();
                var lon = coords[1].toFloat();
                if (lat > 29.0f && lat < 34.0f && lon > 34.0f && lon < 36.0f) {
                    _userLat = lat;
                    _userLon = lon;
                }
                fetchStationsForCoords(_userLat, _userLon);
                return;
            }
        }
        fetchStationsForCoords(_userLat, _userLon);
    }

    public function useFallbackLocation() as Void {
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
        fetchStationsForCoords(_userLat, _userLon);
    }

    private function fetchStationsForCoords(lat as Float, lon as Float) as Void {
        _isScanningGps = false;
        _isFetchingApi = true;
        _statusMessage = "Loading map stops...";
        WatchUi.requestUpdate();

        api_requester.get_nearby_stations(
            lat,
            lon,
            method(:onNearbyStationsLoaded),
            method(:onNearbyStationsError)
        );
    }

    public function onNearbyStationsLoaded(data as Object) as Void {
        _isFetchingApi = false;
        _nearbyStations = [];
        _selectedIndex = 0;

        if (data != null && data instanceof Lang.Array) {
            var arr = data as Array<Dictionary>;
            for (var i = 0; i < arr.size(); i++) {
                var item = arr[i];
                var code = Utils.toStringSafe(item["code"], "");
                if (code.length() == 0) {
                    code = Utils.toStringSafe(item["gtfs_stop__code"], "");
                }
                if (code.length() == 0) {
                    continue;
                }

                // Extract official English name from name["EN"] (or fallback to name["HE"])
                var rawName = "";
                var nameObj = item["name"];
                if (nameObj != null && nameObj instanceof Lang.Dictionary) {
                    var nameDict = nameObj as Dictionary;
                    rawName = Utils.toStringSafe(nameDict["EN"], "");
                    if (rawName.length() == 0) {
                        rawName = Utils.toStringSafe(nameDict["HE"], "");
                    }
                } else {
                    rawName = Utils.toStringSafe(nameObj, "");
                }
                if (rawName.length() == 0) {
                    rawName = Utils.toStringSafe(item["gtfs_stop__name"], "");
                }

                var name = Utils.ensureAsciiStationName(rawName, code);

                // Deduplicate by station code
                var duplicate = false;
                for (var j = 0; j < _nearbyStations.size(); j++) {
                    if (code.equals(_nearbyStations[j].getStationCode())) {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) {
                    continue;
                }

                var sLat = null as Float?;
                var sLon = null as Float?;
                var locObj = item["location"];
                if (locObj != null && locObj instanceof Lang.Dictionary) {
                    var locDict = locObj as Dictionary;
                    sLat = Utils.toFloatSafe(locDict["lat"]);
                    sLon = Utils.toFloatSafe(locDict["lon"]);
                }
                if (sLat == null) {
                    sLat = Utils.toFloatSafe(item["gtfs_stop__lat"]);
                }
                if (sLon == null) {
                    sLon = Utils.toFloatSafe(item["gtfs_stop__lon"]);
                }

                var st = new Station(name, code, [], api_requester);
                var apiDist = Utils.toFloatSafe(item["distance"]);
                if (sLat != null && sLon != null) {
                    st.setCoordinates(sLat, sLon);
                }
                if (apiDist != null) {
                    st.setDistanceMeters(apiDist.toNumber());
                } else if (sLat != null && sLon != null) {
                    var dist = Utils.calculateDistanceMeters(_userLat, _userLon, sLat, sLon);
                    st.setDistanceMeters(dist);
                }
                _nearbyStations.add(st);
            }

            // Sort stations by distance ascending so index 0 is closest to the user
            for (var i = 0; i < _nearbyStations.size(); i++) {
                for (var j = 0; j < _nearbyStations.size() - i - 1; j++) {
                    var d1 = _nearbyStations[j].getDistanceMeters();
                    var d2 = _nearbyStations[j + 1].getDistanceMeters();
                    if (d1 > d2) {
                        var tmp = _nearbyStations[j];
                        _nearbyStations[j] = _nearbyStations[j + 1];
                        _nearbyStations[j + 1] = tmp;
                    }
                }
            }
        }

        if (_nearbyStations.size() == 0) {
            _statusMessage = "No stations found";
        } else {
            // Auto-select initial zoom so nearby stops fit nicely on the road map
            var refIdx = _nearbyStations.size() - 1;
            if (refIdx > 4) {
                refIdx = 4;
            }
            var refDist = _nearbyStations[refIdx].getDistanceMeters();
            if (refDist <= 220) {
                _zoom = 16;
            } else if (refDist <= 550) {
                _zoom = 15;
            } else {
                _zoom = 14;
            }
            requestRoadTiles();
        }
        WatchUi.requestUpdate();
    }

    public function onNearbyStationsError(statusCode as Number, errorMsg as String) as Void {
        _isFetchingApi = false;
        if (statusCode == -104) {
            _statusMessage = "No Phone BLE (-104)";
        } else {
            _statusMessage = errorMsg + " (" + statusCode + ")";
        }
        WatchUi.requestUpdate();
    }

    public function moveSelection(delta as Number) as Void {
        if (_nearbyStations.size() == 0) {
            return;
        }
        _selectedIndex += delta;
        if (_selectedIndex >= _nearbyStations.size()) {
            _selectedIndex = 0;
        } else if (_selectedIndex < 0) {
            _selectedIndex = _nearbyStations.size() - 1;
        }
        WatchUi.requestUpdate();
    }

    public function handleTap(clickX as Number, clickY as Number) as Boolean {
        if (_nearbyStations.size() == 0) {
            return false;
        }

        // Check + / - zoom buttons first
        var zoomHit = MapTileManager.hitTestZoomButtons(clickX, clickY, _screenW, _screenH);
        if (zoomHit == 1) {
            zoomIn();
            return true;
        } else if (zoomHit == -1) {
            zoomOut();
            return true;
        }

        if (_stationScreenX.size() != _nearbyStations.size()) {
            return false;
        }

        var bestIdx = -1;
        var bestDistSq = 900; // 30px tap radius squared

        for (var i = 0; i < _nearbyStations.size(); i++) {
            var dx = clickX - _stationScreenX[i];
            var dy = clickY - _stationScreenY[i];
            var dSq = (dx * dx) + (dy * dy);
            if (dSq < bestDistSq) {
                bestDistSq = dSq;
                bestIdx = i;
            }
        }

        if (bestIdx != -1) {
            if (_selectedIndex == bestIdx) {
                selectCurrentStation();
            } else {
                _selectedIndex = bestIdx;
                WatchUi.requestUpdate();
            }
            return true;
        }
        return false;
    }

    public function selectCurrentStation() as Void {
        if (_isScanningGps) {
            useFallbackLocation();
            return;
        }
        if (_nearbyStations.size() == 0) {
            startGpsSearch();
            return;
        }

        var chosen = _nearbyStations[_selectedIndex];
        chosen.update_station_buses();
        _parentView.openPreviewStation(chosen);
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }

    public function onUpdate(dc as Dc) as Void {
        _screenW = dc.getWidth();
        _screenH = dc.getHeight();
        var w = _screenW;
        var h = _screenH;

        dc.setColor(0x061018, 0x061018);
        dc.clear();

        if (_isScanningGps || _isFetchingApi || _nearbyStations.size() == 0) {
            drawLoadingOrEmptyState(dc, w, h);
            return;
        }

        // Map centered slightly above vertical center to leave room for bottom HUD card
        var mapCx = w / 2;
        var mapCy = (h * 0.44).toNumber();
        var tileSize = _tileManager.getTileSize();

        // 1. Subtle fallback grid + real road map tiles
        drawFallbackGrid(dc, w, h, mapCx, mapCy);
        _tileManager.drawTiles(dc, _userLat, _userLon, _zoom, mapCx, mapCy);

        // 2. Station pins & User GPS beacon aligned to real Web Mercator roads
        drawStationIconsOnMap(dc, w, h, mapCx, mapCy, tileSize);
        drawUserLocationIcon(dc, mapCx, mapCy);

        // 3. Scale bar, Zoom +/- buttons, Top header, and Bottom HUD
        MapTileManager.drawScaleBar(dc, (w * 0.10).toNumber(), (h * 0.72).toNumber(), _userLat, _zoom, tileSize);
        MapTileManager.drawZoomButtons(dc, w, h, _zoom, MIN_ZOOM, MAX_ZOOM, _zoomMode);
        drawTopHeader(dc, w, h);
        drawSelectedStationHUD(dc, w, h);
    }

    private function drawLoadingOrEmptyState(dc as Dc, w as Number, h as Number) as Void {
        var cx = w / 2;
        var cy = (h * 0.42).toNumber();
        var r = (w * 0.24).toNumber();

        dc.setColor(0x0B1E2D, 0x0B1E2D);
        dc.fillCircle(cx, cy, r);
        dc.setColor(0x1E4460, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(cx, cy, r);
        dc.drawCircle(cx, cy, (r * 0.5).toNumber());
        dc.drawLine(cx - r, cy, cx + r, cy);
        dc.drawLine(cx, cy - r, cx, cy + r);

        dc.setColor(0x00AAFF, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            (h * 0.06).toNumber(),
            Graphics.FONT_XTINY,
            "Station Map (GPS)",
            Graphics.TEXT_JUSTIFY_CENTER
        );

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            cy,
            Graphics.FONT_SMALL,
            _statusMessage,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        dc.setColor(0x00FF88, Graphics.COLOR_TRANSPARENT);
        var hint = _isScanningGps ? "SELECT: Default Map" : "SELECT: Retry Scan";
        dc.drawText(
            w / 2,
            (h * 0.76).toNumber(),
            Graphics.FONT_XTINY,
            hint,
            Graphics.TEXT_JUSTIFY_CENTER
        );
    }

    private function drawFallbackGrid(dc as Dc, w as Number, h as Number, cx as Number, cy as Number) as Void {
        dc.setColor(0x13293D, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(0, cy, w, cy);
        dc.drawLine(cx, 0, cx, h);
        dc.drawCircle(cx, cy, (w * 0.22).toNumber());
        dc.drawCircle(cx, cy, (w * 0.38).toNumber());
    }

    private function drawTopHeader(dc as Dc, w as Number, h as Number) as Void {
        var total = _nearbyStations.size();
        var headerText = _zoomMode
            ? ("ZOOM +/- (Z" + _zoom.toString() + ")")
            : ("MAP " + (_selectedIndex + 1).toString() + "/" + total.toString() + " | Z" + _zoom.toString());

        var pillW = (w * 0.54).toNumber();
        var pillH = (h * 0.11).toNumber();
        var pillX = (w - pillW) / 2;
        var pillY = (h * 0.02).toNumber();

        dc.setColor(0x0E1E2B, 0x0E1E2B);
        dc.fillRoundedRectangle(pillX, pillY, pillW, pillH, 7);
        dc.setColor(_zoomMode ? 0x00FF66 : 0x00AAFF, Graphics.COLOR_TRANSPARENT);
        dc.drawRoundedRectangle(pillX, pillY, pillW, pillH, 7);

        dc.setColor(_zoomMode ? 0x00FF66 : Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            pillY + (pillH / 2),
            Graphics.FONT_XTINY,
            headerText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    private function drawUserLocationIcon(dc as Dc, cx as Number, cy as Number) as Void {
        // Dark contrast ring + white border + cyan user GPS beacon
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawCircle(cx, cy, 8);
        dc.setPenWidth(1);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
        dc.fillCircle(cx, cy, 6);
        dc.setColor(0x0088FF, 0x0088FF);
        dc.fillCircle(cx, cy, 4);
    }

    private function drawStationIconsOnMap(
        dc as Dc,
        w as Number,
        h as Number,
        cx as Number,
        cy as Number,
        tileSize as Number
    ) as Void {
        _stationScreenX = [];
        _stationScreenY = [];

        var centerXFloat = MapTileManager.lonToTileX(_userLon, _zoom);
        var centerYFloat = MapTileManager.latToTileY(_userLat, _zoom);

        for (var i = 0; i < _nearbyStations.size(); i++) {
            var st = _nearbyStations[i];
            var pt = MapTileManager.projectToScreen(
                st.getLat(), st.getLon(),
                centerXFloat, centerYFloat, _zoom, cx, cy, tileSize
            );
            var sx = pt[0];
            var sy = pt[1];

            // Slight nudge if overlapping another visible station pin
            for (var j = 0; j < i; j++) {
                var dx = sx - _stationScreenX[j];
                var dy = sy - _stationScreenY[j];
                if ((dx * dx) + (dy * dy) < 100) {
                    sx += ((i % 2 == 0) ? 8 : -8);
                    sy += ((i % 3 == 0) ? -7 : 7);
                }
            }

            _stationScreenX.add(sx);
            _stationScreenY.add(sy);
        }

        // Draw highlighted vector line from User GPS center to the selected station
        if (_selectedIndex >= 0 && _selectedIndex < _stationScreenX.size()) {
            var selX = _stationScreenX[_selectedIndex];
            var selY = _stationScreenY[_selectedIndex];
            dc.setColor(0x0A1926, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(4);
            dc.drawLine(cx, cy, selX, selY);
            dc.setColor(0x00CC66, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(2);
            dc.drawLine(cx, cy, selX, selY);
            dc.setPenWidth(1);
        }

        // Draw unselected station icons first, then selected station icon on top
        var minY = (h * 0.12).toNumber();
        var maxY = (h * 0.76).toNumber();

        for (var i = 0; i < _nearbyStations.size(); i++) {
            if (i == _selectedIndex) {
                continue;
            }
            var sx = _stationScreenX[i];
            var sy = _stationScreenY[i];
            if (sx < -15 || sx > w + 15 || sy < minY - 15 || sy > maxY + 15) {
                continue;
            }
            var st = _nearbyStations[i];
            var isFav = FavoritesStorage.isFavorite(st.getStationCode());
            drawBusStopIcon(dc, sx, sy, false, isFav);
        }

        if (_selectedIndex >= 0 && _selectedIndex < _nearbyStations.size()) {
            var selSt = _nearbyStations[_selectedIndex];
            var selFav = FavoritesStorage.isFavorite(selSt.getStationCode());
            var selX = _stationScreenX[_selectedIndex];
            var selY = _stationScreenY[_selectedIndex];
            // Clamp selected pin gently inside viewport so user always sees direction when zoomed in
            if (selX < 18) {
                selX = 18;
            } else if (selX > w - 40) {
                selX = w - 40;
            }
            if (selY < minY + 10) {
                selY = minY + 10;
            } else if (selY > maxY - 10) {
                selY = maxY - 10;
            }
            drawBusStopIcon(dc, selX, selY, true, selFav);
        }
    }

    // Draws a distinct Bus Stop Icon (bus glyph / pin) at (x, y)
    private function drawBusStopIcon(dc as Dc, x as Number, y as Number, isSelected as Boolean, isFav as Boolean) as Void {
        if (isSelected) {
            // Outer high-contrast selection halo
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(3);
            dc.drawCircle(x, y, 13);
            dc.setColor(0x00FF66, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(2);
            dc.drawCircle(x, y, 12);
            dc.setPenWidth(1);

            // Pin pointer triangle at bottom of bus icon
            dc.setColor(0x00FF66, 0x00FF66);
            dc.fillPolygon([
                [x - 4, y + 6],
                [x + 4, y + 6],
                [x, y + 12]
            ]);

            // Bus body (16x15 rounded rectangle)
            var bgColor = isFav ? 0xFFCC00 : 0x00FF66;
            dc.setColor(bgColor, bgColor);
            dc.fillRoundedRectangle(x - 8, y - 8, 16, 15, 4);

            // Dark outline for high contrast over light roads
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawRoundedRectangle(x - 8, y - 8, 16, 15, 4);

            // Bus windshield window
            dc.setColor(0x0A1926, 0x0A1926);
            dc.fillRectangle(x - 5, y - 5, 10, 5);

            // Bus headlights
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
            dc.fillCircle(x - 4, y + 3, 1);
            dc.fillCircle(x + 4, y + 3, 1);
        } else {
            var bodyColor = isFav ? 0xFFAA00 : 0x0077CC;

            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
            dc.drawLine(x, y + 5, x, y + 8);

            dc.setColor(bodyColor, bodyColor);
            dc.fillRoundedRectangle(x - 5, y - 5, 11, 11, 3);
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawRoundedRectangle(x - 5, y - 5, 11, 11, 3);

            dc.setColor(0x081520, 0x081520);
            dc.fillRectangle(x - 3, y - 3, 7, 4);

            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
            dc.fillRectangle(x - 3, y + 2, 2, 2);
            dc.fillRectangle(x + 2, y + 2, 2, 2);
        }
    }

    private function drawSelectedStationHUD(dc as Dc, w as Number, h as Number) as Void {
        if (_selectedIndex < 0 || _selectedIndex >= _nearbyStations.size()) {
            return;
        }

        var st = _nearbyStations[_selectedIndex];
        var isFav = FavoritesStorage.isFavorite(st.getStationCode());

        var cardY = (h * 0.77).toNumber();
        var cardH = (h * 0.21).toNumber();
        var cardX = (w * 0.14).toNumber();
        var cardW = (w * 0.72).toNumber();

        dc.setColor(0x0E1E2B, 0x0E1E2B);
        dc.fillRoundedRectangle(cardX, cardY, cardW, cardH, 8);
        dc.setColor(isFav ? 0xFFCC00 : 0x00FF66, Graphics.COLOR_TRANSPARENT);
        dc.drawRoundedRectangle(cardX, cardY, cardW, cardH, 8);

        var title = st.getStationName();
        if (title.length() > 15) {
            title = title.substring(0, 13) + "..";
        }
        if (isFav) {
            title = "* " + title;
        }

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            cardY + 1,
            Graphics.FONT_XTINY,
            title,
            Graphics.TEXT_JUSTIFY_CENTER
        );

        var dist = st.getDistanceMeters();
        var dir = getCardinalDirection(_userLat, _userLon, st.getLat(), st.getLon());
        var subText = "#" + st.getStationCode();
        if (dist >= 0) {
            subText += " | " + dist.toString() + "m " + dir;
        }

        dc.setColor(0x00FFAA, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            cardY + (cardH / 2),
            Graphics.FONT_XTINY,
            subText,
            Graphics.TEXT_JUSTIFY_CENTER
        );
    }

    private function getCardinalDirection(lat1 as Float, lon1 as Float, lat2 as Float, lon2 as Float) as String {
        var dLat = lat2 - lat1;
        var dLon = (lon2 - lon1) * Math.cos(lat1 * Math.PI / 180.0);

        var absLat = (dLat < 0) ? -dLat : dLat;
        var absLon = (dLon < 0) ? -dLon : dLon;

        var ns = "";
        if (absLat > absLon * 0.4f) {
            ns = (dLat >= 0) ? "N" : "S";
        }
        var ew = "";
        if (absLon > absLat * 0.4f) {
            ew = (dLon >= 0) ? "E" : "W";
        }
        var dir = ns + ew;
        return (dir.length() > 0) ? dir : "N";
    }
}

class NearbyStationsDelegate extends WatchUi.BehaviorDelegate {

    private var _view as NearbyStationsView;

    public function initialize(view as NearbyStationsView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    public function onNextPage() as Boolean {
        if (_view.isZoomMode()) {
            _view.zoomOut();
        } else {
            _view.moveSelection(1);
        }
        return true;
    }

    public function onPreviousPage() as Boolean {
        if (_view.isZoomMode()) {
            _view.zoomIn();
        } else {
            _view.moveSelection(-1);
        }
        return true;
    }

    public function onPrevPage() as Boolean {
        return onPreviousPage();
    }

    public function onMenu() as Boolean {
        _view.toggleZoomMode();
        return true;
    }

    public function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        var coords = clickEvent.getCoordinates();
        if (coords != null && coords.size() >= 2) {
            if (_view.handleTap(coords[0], coords[1])) {
                return true;
            }
        }
        return false;
    }

    public function onSelect() as Boolean {
        if (_view.isZoomMode()) {
            _view.exitZoomMode();
            return true;
        }
        _view.selectCurrentStation();
        return true;
    }

    public function onBack() as Boolean {
        if (_view.isZoomMode()) {
            _view.exitZoomMode();
            return true;
        }
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}
