import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Timer;

class BusTimesView extends WatchUi.View {

    private var _stations as Array<Station> = [];
    // _page_index: 0..(_stations.size()-1) are stations; _stations.size() is the "Scan Nearby Stations (GPS)" card
    private var _page_index as Number = 0;
    private var _refreshTimer as Timer.Timer?;

    public function initialize() {
        View.initialize();
        reloadFavoritesList();
    }

    public function onShow() as Void {
        if (_refreshTimer == null) {
            _refreshTimer = new Timer.Timer();
            _refreshTimer.start(method(:onAutoRefreshTick), 30000, true);
        }
    }

    public function onHide() as Void {
        if (_refreshTimer != null) {
            _refreshTimer.stop();
            _refreshTimer = null;
        }
    }

    public function onAutoRefreshTick() as Void {
        var current = getCurrentStation();
        if (current != null && !current.isLoading()) {
            current.update_station_buses();
        }
    }

    public function reloadFavoritesList() as Void {
        var favDicts = FavoritesStorage.loadFavorites();
        _stations = [];

        for (var i = 0; i < favDicts.size(); i++) {
            var d = favDicts[i];
            var name = Utils.toStringSafe(d["name"], "Station");
            var code = Utils.toStringSafe(d["code"], "");
            if (code.length() == 0) {
                continue;
            }
            var st = new Station(name, code, [], api_requester);
            var lat = Utils.toFloatSafe(d["lat"]);
            var lon = Utils.toFloatSafe(d["lon"]);
            if (lat != null && lon != null) {
                st.setCoordinates(lat, lon);
            }
            st.retrieve_init_info();
            _stations.add(st);
        }

        if (_page_index > _stations.size()) {
            _page_index = 0;
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

    public function switchPage(is_forward as Boolean) as Void {
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
        if (!isNowFav) {
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

        // Top line: Favorite marker + Stop Code
        var topBadge = (isFav ? "[FAV] " : "") + "Stop #" + code;
        dc.setColor(isFav ? 0xFFCC00 : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            (h * 0.05).toNumber(),
            Graphics.FONT_XTINY,
            topBadge,
            Graphics.TEXT_JUSTIFY_CENTER
        );

        // Station Name (guaranteed ASCII-safe)
        var name = station.getStationName();
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

        for (var i = 0; i < buses.size() && i < maxRows; i++) {
            var bus = buses[i];
            var routeNum = Utils.toStringSafe(bus["route"], "?");
            var etaLabel = Utils.toStringSafe(bus["eta_label"], "--");
            var status = bus["status"] as Number;

            var rowCenterY = startY + (i * rowHeight) + (rowHeight / 2);

            // Indicative color based on status:
            // Green = Live & on-route
            // Gray = Scheduled
            // Orange = Moderate delay since last position update
            // Red = Off-route or very long time since last position update
            var statusColor = Graphics.COLOR_LT_GRAY;
            if (status == Utils.STATUS_LIVE_ON_ROUTE) {
                statusColor = Graphics.COLOR_GREEN;
            } else if (status == Utils.STATUS_STALE_WARN) {
                statusColor = Graphics.COLOR_ORANGE;
            } else if (status == Utils.STATUS_STALE_OR_OFF) {
                statusColor = Graphics.COLOR_RED;
            }

            // Left side: Bus Line Pill Badge (Number only)
            var pillX = (w * 0.15).toNumber();
            var pillW = (w * 0.26).toNumber();
            var pillH = (rowHeight * 0.82).toNumber();
            var pillY = rowCenterY - (pillH / 2);

            dc.setColor(0x1E293B, 0x1E293B);
            dc.fillRoundedRectangle(pillX, pillY, pillW, pillH, 6);
            dc.setColor(statusColor, Graphics.COLOR_TRANSPARENT);
            dc.drawRoundedRectangle(pillX, pillY, pillW, pillH, 6);

            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                pillX + (pillW / 2),
                rowCenterY,
                Graphics.FONT_SMALL,
                routeNum,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );

            // Status indicator dot
            var dotX = (w * 0.47).toNumber();
            dc.setColor(statusColor, statusColor);
            dc.fillCircle(dotX, rowCenterY, 4);

            // Right side: Arrival Time in the indicative status color
            dc.setColor(statusColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                (w * 0.85).toNumber(),
                rowCenterY,
                Graphics.FONT_SMALL,
                etaLabel,
                Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER
            );
        }

        drawColorLegend(dc, w, h, station.isLoading());
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

        dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_GREEN);
        dc.fillCircle(startX, cy, 3);

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_LT_GRAY);
        dc.fillCircle(startX + spacing, cy, 3);

        dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_ORANGE);
        dc.fillCircle(startX + (spacing * 2), cy, 3);

        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_RED);
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
