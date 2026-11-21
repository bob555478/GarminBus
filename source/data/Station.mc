import Toybox.Lang;
import Toybox.Time;
import Toybox.WatchUi;

class Station {
    private var _buses as Array<Dictionary> = [];
    private var _station_name as String = "";
    private var _station_siri_id as String = "None";
    private var _api_requester as ApiRequester;
    private var _station_code as String;
    private var _lat as Float = 32.0628f;
    private var _lon as Float = 34.7905f;
    private var _distance_meters as Number = -1;
    private var _is_loading as Boolean = false;
    private var _error_msg as String? = null;
    private var _interesting_buses as Array<String> = [];

    function initialize(
        station_name as String,
        station_code as String,
        interesting_buses as Array<String>,
        api_requester as ApiRequester
    ) {
        self._station_code = station_code;
        self._station_name = Utils.ensureAsciiStationName(station_name, station_code);
        self._api_requester = api_requester;
        self._interesting_buses = interesting_buses;
    }

    public function setCoordinates(lat as Float, lon as Float) as Void {
        self._lat = lat;
        self._lon = lon;
    }

    public function getLat() as Float {
        return self._lat;
    }

    public function getLon() as Float {
        return self._lon;
    }

    public function setDistanceMeters(dist as Number) as Void {
        self._distance_meters = dist;
    }

    public function getDistanceMeters() as Number {
        return self._distance_meters;
    }

    public function getStationName() as String {
        return self._station_name;
    }

    public function setStationName(name as String) as Void {
        self._station_name = Utils.ensureAsciiStationName(name, self._station_code);
    }

    public function getStationCode() as String {
        return self._station_code;
    }

    public function getStationSiriId() as String {
        return self._station_siri_id;
    }

    public function setStationSiriIdDirect(siriId as String) as Void {
        self._station_siri_id = siriId;
    }

    public function getBuses() as Array<Dictionary> {
        return self._buses;
    }

    public function isLoading() as Boolean {
        return self._is_loading;
    }

    public function getErrorMsg() as String? {
        return self._error_msg;
    }

    public function retrieve_init_info() as Void {
        self._is_loading = true;
        self._error_msg = null;
        WatchUi.requestUpdate();

        // Fetch stop metadata (coordinates and name if not already customized)
        self._api_requester.get_gtfs_stop_info(
            self._station_code,
            method(:on_gtfs_stop_info),
            method(:on_gtfs_stop_error)
        );

        self._api_requester.get_station_siri_id(
            self._station_code,
            method(:set_station_siri_id),
            method(:on_api_error)
        );
    }

    public function on_gtfs_stop_info(data as Object) as Void {
        if (data != null && data instanceof Lang.Array) {
            var arr = data as Array<Dictionary>;
            if (arr.size() > 0) {
                var stop = arr[0];
                var name = stop["name"];
                // Only overwrite station name if current name is generic "Station <code/>"
                var defaultPrefix = "Station ";
                if (name != null && name instanceof Lang.String && name.length() > 0) {
                    if (self._station_name.length() == 0 || self._station_name.find(defaultPrefix) == 0) {
                        self._station_name = Utils.ensureAsciiStationName(name, self._station_code);
                    }
                }
                var lat = Utils.toFloatSafe(stop["lat"]);
                var lon = Utils.toFloatSafe(stop["lon"]);
                if (lat != null && lon != null) {
                    self._lat = lat;
                    self._lon = lon;
                }
                WatchUi.requestUpdate();
            }
        }
    }

    public function on_gtfs_stop_error(statusCode as Number, errorMsg as String) as Void {
        // Non-fatal: keep existing station name and coordinates
    }

    public function update_station_buses() as Void {
        if ("None".equals(self._station_siri_id)) {
            retrieve_init_info();
            return;
        }
        self._is_loading = true;
        self._error_msg = null;
        WatchUi.requestUpdate();

        self._api_requester.get_station_buses(
            self._station_siri_id,
            method(:set_station_buses),
            method(:on_buses_query_error)
        );
    }

    public function on_buses_query_error(statusCode as Number, errorMsg as String) as Void {
        // Fallback without order_by if server rejected order_by parameter
        self._api_requester.get_station_buses_fallback(
            self._station_siri_id,
            method(:set_station_buses),
            method(:on_api_error)
        );
    }

    public function on_api_error(statusCode as Number, errorMsg as String) as Void {
        self._is_loading = false;
        if (statusCode == -104) {
            self._error_msg = "No Phone BLE (-104)";
        } else {
            self._error_msg = errorMsg + " (" + statusCode + ")";
        }
        WatchUi.requestUpdate();
    }

    public function set_station_siri_id(data as Object) as Void {
        if (data != null && data instanceof Lang.Array) {
            var siri_data = data as Array<Dictionary>;
            if (siri_data.size() > 0 && siri_data[0]["id"] != null) {
                self._station_siri_id = siri_data[0]["id"].toString();
                self.update_station_buses();
                return;
            }
        }
        self._is_loading = false;
        self._error_msg = "No real-time stop data";
        WatchUi.requestUpdate();
    }

    public function set_station_buses(data as Object) as Void {
        self._is_loading = false;
        if (data == null || !(data instanceof Lang.Array)) {
            self._buses = [];
            WatchUi.requestUpdate();
            return;
        }

        var buses = data as Array<Dictionary>;
        var nowEpoch = Time.now().value();
        var parsedList = [] as Array<Dictionary>;

        for (var i = 0; i < buses.size(); i++) {
            var item = buses[i];

            var route = Utils.toStringSafe(item["gtfs_route__route_short_name"], "");
            if (route.length() == 0) {
                route = Utils.toStringSafe(item["siri_route__line_ref"], "?");
            }

            // If interesting_buses filter is non-empty, only include matching lines
            if (self._interesting_buses.size() > 0 && self._interesting_buses.indexOf(route) == -1) {
                continue;
            }

            // Extract arrival / scheduled time and last GPS ping timestamp
            var schedTimeStr = Utils.toStringSafe(item["gtfs_ride_stop__arrival_time"], "");
            if (schedTimeStr.length() == 0) {
                schedTimeStr = Utils.toStringSafe(item["siri_ride__scheduled_start_time"], "");
            }

            var recordedTimeStr = Utils.toStringSafe(
                item["nearest_siri_vehicle_location__recorded_at_time"],
                ""
            );

            var busLat = Utils.toFloatSafe(item["nearest_siri_vehicle_location__lat"]);
            var busLon = Utils.toFloatSafe(item["nearest_siri_vehicle_location__lon"]);
            var distFromStart = Utils.toFloatSafe(item["nearest_siri_vehicle_location__distance_from_journey_start"]);
            var siriStopDistMeters = Utils.toFloatSafe(item["nearest_siri_vehicle_location__distance_from_siri_ride_stop_meters"]);

            var schedEpoch = Utils.parseIsoToEpoch(schedTimeStr);
            var recordedEpoch = Utils.parseIsoToEpoch(recordedTimeStr);

            // Compute ETA in minutes
            var etaMinutes = -1;
            var etaLabel = "--";
            var isLive = (recordedEpoch != null);

            if (isLive && (siriStopDistMeters != null || (busLat != null && busLon != null))) {
                var distToStopMeters = 0;
                if (siriStopDistMeters != null && siriStopDistMeters >= 0) {
                    distToStopMeters = siriStopDistMeters.toNumber();
                } else if (busLat != null && busLon != null) {
                    distToStopMeters = Utils.calculateDistanceMeters(
                        busLat,
                        busLon,
                        self._lat,
                        self._lon
                    );
                }
                var distMinutes = (distToStopMeters / 320);
                if (schedEpoch != null && schedEpoch >= nowEpoch - 120) {
                    var schedMin = (schedEpoch - nowEpoch) / 60;
                    if (distToStopMeters < 8000) {
                        etaMinutes = distMinutes;
                    } else {
                        etaMinutes = schedMin;
                    }
                } else {
                    etaMinutes = distMinutes;
                }
            } else if (schedEpoch != null) {
                etaMinutes = (schedEpoch - nowEpoch) / 60;
            }

            if (etaMinutes < 0) {
                etaMinutes = 0;
            }

            if (etaMinutes == 0) {
                etaLabel = "Now";
            } else if (etaMinutes > 99) {
                etaLabel = "99+ min";
            } else {
                etaLabel = etaMinutes.toString() + " min";
            }

            // Determine color status per user requirements:
            // - Gray (STATUS_SCHEDULED): No live GPS data (scheduled only)
            // - Red (STATUS_STALE_OR_OFF): Off-route OR very stale GPS update (> 5 mins)
            // - Orange (STATUS_STALE_WARN): Moderately stale GPS update (2 - 5 mins)
            // - Green (STATUS_LIVE_ON_ROUTE): Live GPS update (< 2 mins) and on route
            var status = Utils.STATUS_SCHEDULED;
            var statusReason = "Sched";

            if (isLive && recordedEpoch != null) {
                var ageSec = nowEpoch - recordedEpoch;
                if (ageSec < 0) {
                    ageSec = 0;
                }

                var isOffRoute = false;
                if (busLat != null && busLon != null) {
                    var distMeters = Utils.calculateDistanceMeters(busLat, busLon, self._lat, self._lon);
                    if (distMeters > 15000) {
                        isOffRoute = true;
                    }
                }
                if (distFromStart != null && distFromStart < 0.0f) {
                    isOffRoute = true;
                }

                if (isOffRoute) {
                    status = Utils.STATUS_STALE_OR_OFF;
                    statusReason = "Off Route";
                } else if (ageSec > 300) {
                    status = Utils.STATUS_STALE_OR_OFF;
                    statusReason = "Stale";
                } else if (ageSec > 120) {
                    status = Utils.STATUS_STALE_WARN;
                    statusReason = "Delayed";
                } else {
                    status = Utils.STATUS_LIVE_ON_ROUTE;
                    statusReason = "Live";
                }
            }

            // Deduplicate by route number if already added with a closer ETA
            var alreadyExists = false;
            for (var j = 0; j < parsedList.size(); j++) {
                if (route.equals(parsedList[j]["route"])) {
                    alreadyExists = true;
                    break;
                }
            }

            if (!alreadyExists) {
                parsedList.add({
                    "route" => route,
                    "eta_min" => etaMinutes,
                    "eta_label" => etaLabel,
                    "status" => status,
                    "status_reason" => statusReason
                });
            }
        }

        // Sort buses by ETA ascending
        for (var i = 0; i < parsedList.size(); i++) {
            for (var j = 0; j < parsedList.size() - i - 1; j++) {
                var aMin = parsedList[j]["eta_min"] as Number;
                var bMin = parsedList[j + 1]["eta_min"] as Number;
                if (aMin > bMin) {
                    var temp = parsedList[j];
                    parsedList[j] = parsedList[j + 1];
                    parsedList[j + 1] = temp;
                }
            }
        }

        self._buses = parsedList;
        WatchUi.requestUpdate();
    }
}
