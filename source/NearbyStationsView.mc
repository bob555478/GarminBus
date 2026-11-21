import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Position;

class NearbyStationsView extends WatchUi.View {

    private var _parentView as BusTimesView;
    private var _nearbyStations as Array<Station> = [];
    private var _selectedIndex as Number = 0;
    private var _isScanningGps as Boolean = true;
    private var _isFetchingApi as Boolean = false;
    private var _statusMessage as String = "Locating GPS...";
    private var _userLat as Float = 32.0628f;
    private var _userLon as Float = 34.7905f;

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
        _statusMessage = "Loading stations...";
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

                // Transliterate Hebrew name from GTFS into clean ASCII English
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
                }
                _nearbyStations.add(st);
            }

            // Sort stations by distance ascending
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
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();

        // Top Header Banner
        dc.setColor(0x00AAFF, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            (h * 0.07).toNumber(),
            Graphics.FONT_XTINY,
            "Nearby Stations (GPS)",
            Graphics.TEXT_JUSTIFY_CENTER
        );

        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine((w * 0.15).toNumber(), (h * 0.19).toNumber(), (w * 0.85).toNumber(), (h * 0.19).toNumber());

        if (_isScanningGps || _isFetchingApi || _nearbyStations.size() == 0) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                w / 2,
                (h * 0.44).toNumber(),
                Graphics.FONT_SMALL,
                _statusMessage,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );

            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            var hint = _isScanningGps ? "SELECT: Use Default GPS" : "SELECT: Retry Scan";
            dc.drawText(
                w / 2,
                (h * 0.65).toNumber(),
                Graphics.FONT_XTINY,
                hint,
                Graphics.TEXT_JUSTIFY_CENTER
            );
            return;
        }

        // Render up to 3 visible stations around _selectedIndex
        var total = _nearbyStations.size();
        var startIdx = _selectedIndex - 1;
        if (startIdx < 0) {
            startIdx = 0;
        }
        if (startIdx + 3 > total && total >= 3) {
            startIdx = total - 3;
        }

        var rowY = (h * 0.23).toNumber();
        var rowH = (h * 0.21).toNumber();

        for (var i = 0; i < 3 && (startIdx + i) < total; i++) {
            var idx = startIdx + i;
            var st = _nearbyStations[idx];
            var isSelected = (idx == _selectedIndex);

            if (isSelected) {
                dc.setColor(0x1A2B3C, 0x1A2B3C);
                dc.fillRoundedRectangle(
                    (w * 0.10).toNumber(),
                    rowY,
                    (w * 0.80).toNumber(),
                    rowH - 4,
                    8
                );
                dc.setColor(0x00AAFF, Graphics.COLOR_TRANSPARENT);
                dc.drawRoundedRectangle(
                    (w * 0.10).toNumber(),
                    rowY,
                    (w * 0.80).toNumber(),
                    rowH - 4,
                    8
                );
            }

            var isFav = FavoritesStorage.isFavorite(st.getStationCode());
            var titleText = st.getStationName();
            if (titleText.length() > 16) {
                titleText = titleText.substring(0, 14) + "..";
            }
            if (isFav) {
                titleText = "* " + titleText;
            }

            dc.setColor(isSelected ? Graphics.COLOR_WHITE : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                w / 2,
                rowY + 2,
                Graphics.FONT_SMALL,
                titleText,
                Graphics.TEXT_JUSTIFY_CENTER
            );

            // Subtitle: station code & distance in meters
            var dist = st.getDistanceMeters();
            var subText = "Stop #" + st.getStationCode();
            if (dist >= 0) {
                subText += " - " + dist.toString() + "m";
            }
            dc.setColor(isSelected ? 0x00FFAA : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                w / 2,
                rowY + (rowH / 2) + 2,
                Graphics.FONT_XTINY,
                subText,
                Graphics.TEXT_JUSTIFY_CENTER
            );

            rowY += rowH;
        }

        // Footer counter
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            (h * 0.88).toNumber(),
            Graphics.FONT_XTINY,
            (_selectedIndex + 1).toString() + "/" + total.toString() + " - SELECT to Open",
            Graphics.TEXT_JUSTIFY_CENTER
        );
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

    public function onSelect() as Boolean {
        _view.selectCurrentStation();
        return true;
    }

    public function onBack() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}
