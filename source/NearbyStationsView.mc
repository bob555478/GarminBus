import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Position;
import Toybox.Math;

class NearbyStationsView extends WatchUi.View {

    private var _parentView as BusTimesView;
    private var _nearbyStations as Array<Station> = [];
    private var _selectedIndex as Number = 0;
    private var _isScanningGps as Boolean = true;
    private var _isFetchingApi as Boolean = false;
    private var _statusMessage as String = "Locating GPS...";
    private var _userLat as Float = 32.0628f;
    private var _userLon as Float = 34.7905f;
    private var _maxRadiusMeters as Float = 500.0f;

    // Cache last computed screen coordinates of stations for tap selection on touchscreens
    private var _stationScreenX as Array<Number> = [];
    private var _stationScreenY as Array<Number> = [];

    public function initialize(parentView as BusTimesView) {
        View.initialize();
        _parentView = parentView;
    }

    public function onShow() as Void {
        if (_nearbyStations.size() == 0 && !_isFetchingApi) {
            startGpsSearch();
        }
    }

    public function onHide() as Void {
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
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
        var maxDist = 250;

        if (data != null && data instanceof Lang.Array) {
            var arr = data as Array<Dictionary>;
            for (var i = 0; i < arr.size(); i++) {
                var item = arr[i];
                var code = Utils.toStringSafe(item["gtfs_stop__code"], "");
                if (code.length() == 0) {
                    code = Utils.toStringSafe(item["siri_stop__code"], "");
                }
                if (code.length() == 0) {
                    code = Utils.toStringSafe(item["code"], "");
                }
                if (code.length() == 0) {
                    continue;
                }

                var rawName = Utils.toStringSafe(item["gtfs_stop__name"], "");
                if (rawName.length() == 0) {
                    rawName = Utils.toStringSafe(item["name"], "");
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

                var sLat = Utils.toFloatSafe(item["gtfs_stop__lat"]);
                if (sLat == null) {
                    sLat = Utils.toFloatSafe(item["lat"]);
                }
                var sLon = Utils.toFloatSafe(item["gtfs_stop__lon"]);
                if (sLon == null) {
                    sLon = Utils.toFloatSafe(item["lon"]);
                }

                var st = new Station(name, code, [], api_requester);
                var siriStopId = Utils.toStringSafe(item["siri_stop_id"], "");
                if (siriStopId.length() > 0) {
                    st.setStationSiriIdDirect(siriStopId);
                }
                if (sLat != null && sLon != null) {
                    st.setCoordinates(sLat, sLon);
                    var dist = Utils.calculateDistanceMeters(_userLat, _userLon, sLat, sLon);
                    st.setDistanceMeters(dist);
                    if (dist > maxDist) {
                        maxDist = dist;
                    }
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

        // Add padding to max radius so outer pins stay comfortably inside the map circle
        _maxRadiusMeters = (maxDist * 1.18f).toFloat();
        if (_maxRadiusMeters < 200.0f) {
            _maxRadiusMeters = 200.0f;
        }

        if (_nearbyStations.size() == 0) {
            _statusMessage = "No stations found";
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
        if (_nearbyStations.size() == 0 || _stationScreenX.size() != _nearbyStations.size()) {
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
        dc.setColor(0x061018, 0x061018);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();

        if (_isScanningGps || _isFetchingApi || _nearbyStations.size() == 0) {
            drawLoadingOrEmptyState(dc, w, h);
            return;
        }

        // Map geometry centered slightly above vertical center to leave room for the bottom info card
        var mapCx = w / 2;
        var mapCy = (h * 0.43).toNumber();
        var mapR = (w * 0.34).toNumber();

        drawRadarMapBackground(dc, w, h, mapCx, mapCy, mapR);
        drawStationIconsOnMap(dc, mapCx, mapCy, mapR);
        drawUserLocationIcon(dc, mapCx, mapCy);
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

    private function drawTopHeader(dc as Dc, w as Number, h as Number) as Void {
        var total = _nearbyStations.size();
        var headerText = "MAP " + (_selectedIndex + 1).toString() + "/" + total.toString();

        dc.setColor(0x00AAFF, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            (h * 0.02).toNumber(),
            Graphics.FONT_XTINY,
            headerText,
            Graphics.TEXT_JUSTIFY_CENTER
        );
    }

    private function drawRadarMapBackground(dc as Dc, w as Number, h as Number, cx as Number, cy as Number, r as Number) as Void {
        // Dark map canvas disc
        dc.setColor(0x0B1A26, 0x0B1A26);
        dc.fillCircle(cx, cy, r);

        // Diagonal subtle street/grid lines
        var diag = (r * 0.707f).toNumber();
        dc.setColor(0x112638, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cx - diag, cy - diag, cx + diag, cy + diag);
        dc.drawLine(cx - diag, cy + diag, cx + diag, cy - diag);

        // North-South & East-West crosshair axes
        dc.setColor(0x18364C, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cx - r, cy, cx + r, cy);
        dc.drawLine(cx, cy - r, cx, cy + r);

        // Inner range ring (50% radius)
        var innerR = (r * 0.5).toNumber();
        dc.setColor(0x1D425E, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(cx, cy, innerR);

        // Outer map border ring
        dc.setColor(0x285B80, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawCircle(cx, cy, r);
        dc.setPenWidth(1);

        // Cardinal 'N' indicator at top of map ring
        dc.setColor(0xFF5555, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx + 8,
            cy - r + 1,
            Graphics.FONT_XTINY,
            "N",
            Graphics.TEXT_JUSTIFY_LEFT
        );

        // Scale indicator label (radius in meters) on right edge
        var scaleMeters = (_maxRadiusMeters / 10).toNumber() * 10;
        dc.setColor(0x557799, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx + r - 4,
            cy + 2,
            Graphics.FONT_XTINY,
            scaleMeters.toString() + "m",
            Graphics.TEXT_JUSTIFY_RIGHT
        );
    }

    private function drawUserLocationIcon(dc as Dc, cx as Number, cy as Number) as Void {
        // Outer GPS pulse halo
        dc.setColor(0x004466, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(cx, cy, 8);

        // White border + Cyan user position beacon
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
        dc.fillCircle(cx, cy, 5);
        dc.setColor(0x00E5FF, 0x00E5FF);
        dc.fillCircle(cx, cy, 3);
    }

    private function drawStationIconsOnMap(dc as Dc, cx as Number, cy as Number, mapR as Number) as Void {
        _stationScreenX = [];
        _stationScreenY = [];

        var rad = Math.PI / 180.0;
        var cosLat = Math.cos(_userLat * rad);
        var usableR = mapR - 11; // Keep icons inside the circle border

        // First compute all screen positions
        for (var i = 0; i < _nearbyStations.size(); i++) {
            var st = _nearbyStations[i];
            var dLat = st.getLat() - _userLat;
            var dLon = st.getLon() - _userLon;

            // Equirectangular projection in meters from user location (East = +X, North = +Y -> Screen -Y)
            var eastMeters = dLon * 111320.0f * cosLat;
            var northMeters = dLat * 110540.0f;

            var normX = eastMeters / _maxRadiusMeters;
            var normY = northMeters / _maxRadiusMeters;

            // Clamp within circular boundary
            var distNorm = Math.sqrt((normX * normX) + (normY * normY));
            if (distNorm > 1.0f) {
                normX = normX / distNorm;
                normY = normY / distNorm;
            }

            var sx = cx + (normX * usableR).toNumber();
            var sy = cy - (normY * usableR).toNumber();

            // Nudge slightly if overlapping another station pin
            for (var j = 0; j < i; j++) {
                var dx = sx - _stationScreenX[j];
                var dy = sy - _stationScreenY[j];
                if ((dx * dx) + (dy * dy) < 120) {
                    sx += ((i % 2 == 0) ? 9 : -9);
                    sy += ((i % 3 == 0) ? -8 : 8);
                }
            }

            _stationScreenX.add(sx);
            _stationScreenY.add(sy);
        }

        // Draw dashed/highlighted vector line from User GPS center to the currently selected station
        if (_selectedIndex >= 0 && _selectedIndex < _stationScreenX.size()) {
            var selX = _stationScreenX[_selectedIndex];
            var selY = _stationScreenY[_selectedIndex];
            dc.setColor(0x008855, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(2);
            dc.drawLine(cx, cy, selX, selY);
            dc.setPenWidth(1);
        }

        // Second pass: draw unselected station icons first, then the selected station icon on top
        for (var i = 0; i < _nearbyStations.size(); i++) {
            if (i == _selectedIndex) {
                continue;
            }
            var st = _nearbyStations[i];
            var isFav = FavoritesStorage.isFavorite(st.getStationCode());
            drawBusStopIcon(dc, _stationScreenX[i], _stationScreenY[i], false, isFav);
        }

        if (_selectedIndex >= 0 && _selectedIndex < _nearbyStations.size()) {
            var selSt = _nearbyStations[_selectedIndex];
            var selFav = FavoritesStorage.isFavorite(selSt.getStationCode());
            drawBusStopIcon(dc, _stationScreenX[_selectedIndex], _stationScreenY[_selectedIndex], true, selFav);
        }
    }

    // Draws a distinct Bus Stop Icon (bus glyph / pin) at (x, y)
    private function drawBusStopIcon(dc as Dc, x as Number, y as Number, isSelected as Boolean, isFav as Boolean) as Void {
        if (isSelected) {
            // Outer selection reticle halo
            dc.setColor(0x00FF66, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(2);
            dc.drawCircle(x, y, 13);
            dc.setPenWidth(1);

            // Pin pointer triangle at bottom of bus icon
            dc.setColor(0x00FF66, 0x00FF66);
            dc.fillPolygon([
                [x - 4, y + 6],
                [x + 4, y + 6],
                [x, y + 12]
            ]);

            // Bus body (16x14 rounded rectangle)
            var bgColor = isFav ? 0xFFCC00 : 0x00FF66;
            dc.setColor(bgColor, bgColor);
            dc.fillRoundedRectangle(x - 8, y - 8, 16, 15, 4);

            // Dark outline for high contrast
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            dc.drawRoundedRectangle(x - 8, y - 8, 16, 15, 4);

            // Bus windshield window
            dc.setColor(0x0A1926, 0x0A1926);
            dc.fillRectangle(x - 5, y - 5, 10, 5);

            // Bus headlights (two bright dots)
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
            dc.fillCircle(x - 4, y + 3, 1);
            dc.fillCircle(x + 4, y + 3, 1);
        } else {
            // Unselected bus stop icon: compact 12x12 bus sign with windshield & wheels
            var bodyColor = isFav ? 0xFFAA00 : 0x0099EE;

            // Pin stem
            dc.setColor(bodyColor, bodyColor);
            dc.drawLine(x, y + 5, x, y + 8);

            // Bus icon body
            dc.fillRoundedRectangle(x - 5, y - 5, 11, 11, 3);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawRoundedRectangle(x - 5, y - 5, 11, 11, 3);

            // Bus windshield
            dc.setColor(0x081520, 0x081520);
            dc.fillRectangle(x - 3, y - 3, 7, 4);

            // Headlight dots
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

        // Bottom HUD Card
        var cardY = (h * 0.77).toNumber();
        var cardH = (h * 0.21).toNumber();
        var cardX = (w * 0.14).toNumber();
        var cardW = (w * 0.72).toNumber();

        dc.setColor(0x122636, 0x122636);
        dc.fillRoundedRectangle(cardX, cardY, cardW, cardH, 8);
        dc.setColor(isFav ? 0xFFCC00 : 0x00FF66, Graphics.COLOR_TRANSPARENT);
        dc.drawRoundedRectangle(cardX, cardY, cardW, cardH, 8);

        // Station Name
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

        // Stop Code + Distance & Bearing
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
        _view.moveSelection(1);
        return true;
    }

    public function onPreviousPage() as Boolean {
        _view.moveSelection(-1);
        return true;
    }

    public function onPrevPage() as Boolean {
        _view.moveSelection(-1);
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
        _view.selectCurrentStation();
        return true;
    }

    public function onBack() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}
