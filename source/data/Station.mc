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
    private var _last_fetch_epoch as Number = 0;
    private var _next_refresh_epoch as Number = 0;

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

    public function getLastFetchEpoch() as Number {
        return self._last_fetch_epoch;
    }

    public function getNextRefreshEpoch() as Number {
        return self._next_refresh_epoch;
    }

    public function setNextRefreshEpoch(epoch as Number) as Void {
        self._next_refresh_epoch = epoch;
    }

    // Adaptive refresh interval (minimum 45s), scaling up when the soonest bus is further away
    public function computeAdaptiveIntervalSec() as Number {
        if (self._buses.size() == 0) {
            return 120;
        }
        var minEtaObj = self._buses[0]["eta_min"];
        var minEta = (minEtaObj != null && minEtaObj instanceof Lang.Number) ? (minEtaObj as Number) : 5;
        if (minEta <= 5) {
            return 45;
        } else if (minEta <= 10) {
            return 60;
        } else if (minEta <= 15) {
            return 90;
        } else if (minEta <= 25) {
            return 120;
        } else if (minEta <= 45) {
            return 180;
        }
        return 240;
    }

    // Locally count down ETAs and age GPS timestamps between API refreshes (no network call)
    public function tickCountdowns() as Void {
        if (self._buses.size() == 0) {
            return;
        }
        var watchNow = Time.now().value();
        for (var i = 0; i < self._buses.size(); i++) {
            var bus = self._buses[i];
            var etaLocalObj = bus["eta_local_epoch"];
            if (etaLocalObj != null && etaLocalObj instanceof Lang.Number) {
                var remSec = (etaLocalObj as Number) - watchNow;
                var etaMins = (remSec > 30) ? ((remSec + 30) / 60).toNumber() : 0;
                if (etaMins < 0) {
                    etaMins = 0;
                }
                bus["eta_min"] = etaMins;
                bus["eta_label"] = Utils.formatEtaFromSeconds(remSec);
            }

            var nextEtaLocalObj = bus["next_eta_local_epoch"];
            if (nextEtaLocalObj != null && nextEtaLocalObj instanceof Lang.Number) {
                var nextRemSec = (nextEtaLocalObj as Number) - watchNow;
                bus["next_eta_label"] = Utils.formatEtaCompactFromSeconds(nextRemSec);
            }

            var isLiveObj = bus["is_live"];
            var isLive = (isLiveObj != null && isLiveObj instanceof Lang.Boolean) ? (isLiveObj as Boolean) : false;
            var pingLocalObj = bus["ping_local_epoch"];
            if (isLive && pingLocalObj != null && pingLocalObj instanceof Lang.Number) {
                var ageSec = watchNow - (pingLocalObj as Number);
                if (ageSec < 0) {
                    ageSec = 0;
                }
                bus["gps_age_sec"] = ageSec;
                var offObj = bus["is_off_route"];
                var isOff = (offObj != null && offObj instanceof Lang.Boolean) ? (offObj as Boolean) : false;
                if (isOff) {
                    bus["status"] = Utils.STATUS_STALE_OR_OFF;
                    bus["status_reason"] = "Off Route";
                } else if (ageSec > 300) {
                    bus["status"] = Utils.STATUS_STALE_OR_OFF;
                    bus["status_reason"] = "Stale";
                } else if (ageSec > 120) {
                    bus["status"] = Utils.STATUS_STALE_WARN;
                    bus["status_reason"] = "Delayed";
                } else {
                    bus["status"] = Utils.STATUS_LIVE_ON_ROUTE;
                    bus["status_reason"] = "Live";
                }
            }
        }
    }

    public function retrieve_init_info() as Void {
        update_station_buses();
    }

    public function update_station_buses() as Void {
        self._is_loading = true;
        self._error_msg = null;
        var watchNow = Time.now().value();
        self._last_fetch_epoch = watchNow;
        self._next_refresh_epoch = watchNow + 45;
        WatchUi.requestUpdate();

        self._api_requester.get_station_arrivals(
            self._station_code,
            method(:on_arrivals_received),
            method(:on_api_error)
        );
    }

    public function on_api_error(statusCode as Number, errorMsg as String) as Void {
        self._is_loading = false;
        self._next_refresh_epoch = Time.now().value() + 45;
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

        var watchNow = Time.now().value();
        var nowEpoch = watchNow;
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

            // Compute ETA in seconds and map to watch clock for drift-free local countdowns
            var remainingSec = 0;
            if (etaEpoch != null) {
                remainingSec = etaEpoch - nowEpoch;
                // Skip buses whose ETA already passed more than 60s ago
                if (remainingSec < -60) {
                    continue;
                }
            } else if (isLive && busLat != null && busLon != null) {
                var distMeters = Utils.calculateDistanceMeters(busLat, busLon, self._lat, self._lon);
                remainingSec = ((distMeters / 320).toNumber()) * 60;
            }
            if (remainingSec < 0) {
                remainingSec = 0;
            }

            var etaLocalEpoch = watchNow + remainingSec;
            var etaMinutes = (remainingSec > 30) ? ((remainingSec + 30) / 60).toNumber() : 0;
            var etaLabel = Utils.formatEtaFromSeconds(remainingSec);

            // Determine color status per user requirements:
            // - Gray (STATUS_SCHEDULED): Scheduled time only (location == null)
            // - Red (STATUS_STALE_OR_OFF): Off-route OR very stale GPS update (> 5 mins)
            // - Orange (STATUS_STALE_WARN): Moderately stale GPS update (2 - 5 mins)
            // - Green (STATUS_LIVE_ON_ROUTE): Live GPS update (< 2 mins) and on route
            var status = Utils.STATUS_SCHEDULED;
            var statusReason = "Sched";
            var isOffRoute = false;
            var ageSec = -1;
            var pingLocalEpoch = null as Number?;

            if (isLive) {
                ageSec = 0;
                if (pingEpoch != null) {
                    ageSec = nowEpoch - pingEpoch;
                    if (ageSec < 0) {
                        ageSec = 0;
                    }
                }
                pingLocalEpoch = watchNow - ageSec;

                // Check off-route status
                var statusField = Utils.toStringSafe(item["status"], "");
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
            var operatorId = Utils.toStringSafe(item["operator_id"], "");
            var routeId = Utils.toStringSafe(item["route_id"], "");
            if (routeId.length() == 0) {
                routeId = Utils.toStringSafe(item["line_id"], "");
            }

            parsedList.add({
                "route" => route,
                "eta_min" => etaMinutes,
                "eta_label" => etaLabel,
                "eta_local_epoch" => etaLocalEpoch,
                "ping_local_epoch" => pingLocalEpoch,
                "gps_age_sec" => ageSec,
                "is_off_route" => isOffRoute,
                "status" => status,
                "status_reason" => statusReason,
                "is_live" => isLive,
                "bus_lat" => busLat,
                "bus_lon" => busLon,
                "dest_lat" => destLat,
                "dest_lon" => destLon,
                "dest_name" => destName,
                "vehicle_ref" => vehicleRef,
                "operator_id" => operatorId,
                "route_id" => routeId
            });
        }

        // Sort all arrivals by ETA ascending first
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

        // Group by route number so each line shows its nearest bus time and, in small text after it, the bus afterwards time
        var groupedList = [] as Array<Dictionary>;
        for (var i = 0; i < parsedList.size(); i++) {
            var item = parsedList[i];
            var route = Utils.toStringSafe(item["route"], "?");
            var foundIdx = -1;
            for (var g = 0; g < groupedList.size(); g++) {
                if (route.equals(groupedList[g]["route"])) {
                    foundIdx = g;
                    break;
                }
            }

            if (foundIdx == -1) {
                groupedList.add(item);
            } else {
                var primary = groupedList[foundIdx];
                if (primary["next_eta_local_epoch"] == null) {
                    var nextEpochObj = item["eta_local_epoch"];
                    if (nextEpochObj != null && nextEpochObj instanceof Lang.Number) {
                        var nextEpoch = nextEpochObj as Number;
                        primary["next_eta_local_epoch"] = nextEpoch;
                        primary["next_eta_label"] = Utils.formatEtaCompactFromSeconds(nextEpoch - watchNow);
                        primary["next_status"] = item["status"];
                    }
                }
            }
        }

        self._buses = groupedList;
        self._last_fetch_epoch = watchNow;
        self._next_refresh_epoch = watchNow + computeAdaptiveIntervalSec();
        WatchUi.requestUpdate();
    }
}
