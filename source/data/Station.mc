import Toybox.Lang;
import Toybox.Time;
import Toybox.WatchUi;

class Station {
    private var _buses as Array<Dictionary> = [];
    private var _station_name as String = "";
    private var _nickname as String = "";
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

    public function getNickname() as String {
        return self._nickname;
    }

    public function setNickname(nick as String) as Void {
        if (nick.length() > 0) {
            self._nickname = Utils.ensureAsciiStationName(nick, self._station_code);
        } else {
            self._nickname = "";
        }
    }

    public function getDisplayName() as String {
        if (self._nickname.length() > 0) {
            return self._nickname;
        }
        return self._station_name;
    }

    public function getStationCode() as String {
        return self._station_code;
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
        update_station_buses();
    }

    public function update_station_buses() as Void {
        self._is_loading = true;
        self._error_msg = null;
        WatchUi.requestUpdate();

        self._api_requester.get_station_arrivals(
            self._station_code,
            method(:on_arrivals_received),
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

    public function on_arrivals_received(data as Object) as Void {
        self._is_loading = false;
        if (data == null || !(data instanceof Lang.Dictionary)) {
            self._buses = [];
            WatchUi.requestUpdate();
            return;
        }

        var resp = data as Dictionary;

        // 1. Update station official English name and coordinates from stop_info if present
        var stopInfoObj = resp["stop_info"];
        if (stopInfoObj != null && stopInfoObj instanceof Lang.Dictionary) {
            var stopInfo = stopInfoObj as Dictionary;
            var nameObj = stopInfo["name"];
            if (nameObj != null && nameObj instanceof Lang.Dictionary) {
                var nameDict = nameObj as Dictionary;
                var enName = Utils.toStringSafe(nameDict["EN"], "");
                var heName = Utils.toStringSafe(nameDict["HE"], "");
                if (enName.length() > 0) {
                    self._station_name = Utils.ensureAsciiStationName(enName, self._station_code);
                } else if (heName.length() > 0) {
                    self._station_name = Utils.ensureAsciiStationName(heName, self._station_code);
                }
            }
            var locObj = stopInfo["location"];
            if (locObj != null && locObj instanceof Lang.Dictionary) {
                var locDict = locObj as Dictionary;
                var lat = Utils.toFloatSafe(locDict["lat"]);
                var lon = Utils.toFloatSafe(locDict["lon"]);
                if (lat != null && lon != null) {
                    self._lat = lat;
                    self._lon = lon;
                }
            }
        }

        // 2. Parse real-time and scheduled bus visits
        var visitsContainer = resp["visits"];
        var visitsList = [] as Array<Dictionary>;
        if (visitsContainer != null && visitsContainer instanceof Lang.Dictionary) {
            var vDict = visitsContainer as Dictionary;
            var stopVisits = vDict[self._station_code];
            if (stopVisits != null && stopVisits instanceof Lang.Array) {
                visitsList = stopVisits as Array<Dictionary>;
            }
        }

        var nowEpoch = Time.now().value();
        var respTimeStr = Utils.toStringSafe(resp["timestamp"], "");
        var respEpoch = Utils.parseIsoToEpoch(respTimeStr);
        if (respEpoch != null) {
            nowEpoch = respEpoch;
        }

        var parsedList = [] as Array<Dictionary>;

        for (var i = 0; i < visitsList.size(); i++) {
            var item = visitsList[i];

            var rawRoute = Utils.toStringSafe(item["line_name"], "?");
            var route = Utils.ensureAsciiStationName(rawRoute, "?");

            if (self._interesting_buses.size() > 0 && self._interesting_buses.indexOf(route) == -1) {
                continue;
            }

            var etaStr = Utils.toStringSafe(item["eta"], "");
            var pingTimestampStr = Utils.toStringSafe(item["timestamp"], "");
            var etaEpoch = Utils.parseIsoToEpoch(etaStr);
            var pingEpoch = Utils.parseIsoToEpoch(pingTimestampStr);

            // Check live GPS coordinates
            var locObj = item["location"];
            var busLat = null as Float?;
            var busLon = null as Float?;
            if (locObj != null && locObj instanceof Lang.Dictionary) {
                var locDict = locObj as Dictionary;
                busLat = Utils.toFloatSafe(locDict["lat"]);
                busLon = Utils.toFloatSafe(locDict["lon"]);
            }

            var isLive = (busLat != null && busLon != null);

            // Compute ETA in minutes
            var etaMinutes = 0;
            if (etaEpoch != null) {
                etaMinutes = ((etaEpoch - nowEpoch) / 60).toNumber();
            } else if (isLive && busLat != null && busLon != null) {
                var distMeters = Utils.calculateDistanceMeters(busLat, busLon, self._lat, self._lon);
                etaMinutes = (distMeters / 320).toNumber();
            }

            if (etaMinutes < 0) {
                etaMinutes = 0;
            }

            var etaLabel = "--";
            if (etaMinutes == 0) {
                etaLabel = "Now";
            } else if (etaMinutes > 99) {
                etaLabel = "99+ min";
            } else {
                etaLabel = etaMinutes.toString() + " min";
            }

            // Determine color status per user requirements:
            // - Gray (STATUS_SCHEDULED): Scheduled time only (location == null)
            // - Red (STATUS_STALE_OR_OFF): Off-route OR very stale GPS update (> 5 mins)
            // - Orange (STATUS_STALE_WARN): Moderately stale GPS update (2 - 5 mins)
            // - Green (STATUS_LIVE_ON_ROUTE): Live GPS update (< 2 mins) and on route
            var status = Utils.STATUS_SCHEDULED;
            var statusReason = "Sched";

            if (isLive) {
                var ageSec = 0;
                if (pingEpoch != null) {
                    ageSec = nowEpoch - pingEpoch;
                    if (ageSec < 0) {
                        ageSec = 0;
                    }
                }

                // Check off-route status
                var statusField = Utils.toStringSafe(item["status"], "");
                var isOffRoute = false;
                if (statusField.find("off") != null || statusField.find("deviat") != null || statusField.find("cancel") != null) {
                    isOffRoute = true;
                }
                if (busLat != null && busLon != null) {
                    var distToStop = Utils.calculateDistanceMeters(busLat, busLon, self._lat, self._lon);
                    // If bus is > 25km away or ETA is 0 min while > 1.5km away -> off-route anomaly
                    if (distToStop > 25000 || (etaMinutes <= 1 && distToStop > 1500)) {
                        isOffRoute = true;
                    }
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

            // Extract destination & route metadata from static_info if present
            var destLat = null as Float?;
            var destLon = null as Float?;
            var destName = "";
            var staticInfoObj = item["static_info"];
            if (staticInfoObj != null && staticInfoObj instanceof Lang.Dictionary) {
                var staticDict = staticInfoObj as Dictionary;
                var routeObj = staticDict["route"];
                if (routeObj != null && routeObj instanceof Lang.Dictionary) {
                    var routeDict = routeObj as Dictionary;
                    var destObj = routeDict["destination"];
                    if (destObj != null && destObj instanceof Lang.Dictionary) {
                        var destDict = destObj as Dictionary;
                        var dLocObj = destDict["location"];
                        if (dLocObj != null && dLocObj instanceof Lang.Dictionary) {
                            var dLoc = dLocObj as Dictionary;
                            destLat = Utils.toFloatSafe(dLoc["lat"]);
                            destLon = Utils.toFloatSafe(dLoc["lon"]);
                        }
                        var dNameObj = destDict["name"];
                        if (dNameObj != null && dNameObj instanceof Lang.Dictionary) {
                            var dNameDict = dNameObj as Dictionary;
                            var rawDest = Utils.toStringSafe(dNameDict["EN"], "");
                            if (rawDest.length() == 0) {
                                rawDest = Utils.toStringSafe(dNameDict["HE"], "");
                            }
                            if (rawDest.length() > 0) {
                                destName = Utils.ensureAsciiStationName(rawDest, "");
                            }
                        }
                    }
                }
            }

            var vehicleRef = Utils.toStringSafe(item["vehicle_ref"], "");
            var routeId = Utils.toStringSafe(item["route_id"], "");

            parsedList.add({
                "route" => route,
                "eta_min" => etaMinutes,
                "eta_label" => etaLabel,
                "status" => status,
                "status_reason" => statusReason,
                "is_live" => isLive,
                "bus_lat" => busLat,
                "bus_lon" => busLon,
                "dest_lat" => destLat,
                "dest_lon" => destLon,
                "dest_name" => destName,
                "vehicle_ref" => vehicleRef,
                "route_id" => routeId
            });
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
