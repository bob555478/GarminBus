import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.Time;
import Toybox.Timer;
import Toybox.WatchUi;

class BusRouteMapView extends WatchUi.View {

    private static const MIN_ZOOM = 10;
    private static const MAX_ZOOM = 17;

    private static const FOCUS_FIT = 0;
    private static const FOCUS_BUS = 1;
    private static const FOCUS_STOP = 2;
    private static const FOCUS_USER = 3;

    private var _station as Station;
    private var _routeNum as String;
    private var _routeId as String;
    private var _etaLabel as String;
    private var _etaMin as Number;
    private var _etaLocalEpoch as Number? = null;
    private var _pingLocalEpoch as Number? = null;
    private var _lastBusRefreshEpoch as Number = 0;
    private var _status as Number;
    private var _statusReason as String;
    private var _isLive as Boolean;
    private var _busLat as Float?;
    private var _busLon as Float?;
    private var _userLat as Float? = null;
    private var _userLon as Float? = null;
    private var _destLat as Float?;
    private var _destLon as Float?;
    private var _destName as String;
    private var _vehicleRef as String;

    private var _tileManager as MapTileManager;
    private var _zoom as Number = 14;
    private var _userZoomedManually as Boolean = false;
    private var _focusMode as Number = FOCUS_FIT;
    private var _centerLat as Float;
    private var _centerLon as Float;

    // Route polyline points (from OSRM)
    private var _routeLats as Array<Float> = [];
    private var _routeLons as Array<Float> = [];
    private var _lastRouteBusLat as Float? = null;
    private var _lastRouteBusLon as Float? = null;
    private var _isFetchingRoute as Boolean = false;
    private var _isRefreshingBus as Boolean = false;

    // Stops along the bus route (from Open Bus Stride GTFS, loaded in 10-stop pages)
    private var _stopLats as Array<Float> = [];      // Other stops (drawn as small black dots)
    private var _stopLons as Array<Float> = [];
    private var _allStopLats as Array<Float> = [];   // All ordered route stops (used to trace exact bus path)
    private var _allStopLons as Array<Float> = [];
    private var _hasFullStopRoute as Boolean = false;
    private var _isFetchingStops as Boolean = false;
    private var _stopsRideId as Number = -1;
    private var _stopsStartTime as String = "";
    private var _stopsEndTime as String = "";
    private var _stopsOffset as Number = 0;

    private var _refreshTimer as Timer.Timer?;
    private var _screenW as Number = 260;
    private var _screenH as Number = 260;

    // Pre-projected screen-space cache for static route polyline & stops
    // Avoids repeating 300+ trig projections on every bus/GPS/countdown redraw
    private var _cachedRouteX as Array<Number> = [];
    private var _cachedRouteY as Array<Number> = [];
    private var _cachedStopX as Array<Number> = [];
    private var _cachedStopY as Array<Number> = [];
    private var _cacheZoom as Number = -1;
    private var _cacheCenterLat as Float = 0.0f;
    private var _cacheCenterLon as Float = 0.0f;
    private var _cacheRouteCount as Number = -1;
    private var _cacheStopCount as Number = -1;
    private var _cacheTileSize as Number = -1;
    private var _lastUserScreenX as Number = -999;
    private var _lastUserScreenY as Number = -999;

    public function initialize(station as Station, busInfo as Dictionary) {
        View.initialize();
        _station = station;
        _tileManager = new MapTileManager();

        _routeNum = Utils.toStringSafe(busInfo["route"], "?");
        _routeId = Utils.toStringSafe(busInfo["route_id"], "");
        _etaLabel = Utils.toStringSafe(busInfo["eta_label"], "--");
        var etaVal = busInfo["eta_min"];
        _etaMin = (etaVal != null && etaVal instanceof Lang.Number) ? (etaVal as Number) : 0;
        var etaLocalObj = busInfo["eta_local_epoch"];
        if (etaLocalObj != null && etaLocalObj instanceof Lang.Number) {
            _etaLocalEpoch = etaLocalObj as Number;
        }
        var pingLocalObj = busInfo["ping_local_epoch"];
        if (pingLocalObj != null && pingLocalObj instanceof Lang.Number) {
            _pingLocalEpoch = pingLocalObj as Number;
        }
        _lastBusRefreshEpoch = Time.now().value();
        var stVal = busInfo["status"];
        _status = (stVal != null && stVal instanceof Lang.Number) ? (stVal as Number) : Utils.STATUS_SCHEDULED;
        _statusReason = Utils.toStringSafe(busInfo["status_reason"], "Sched");
        var liveVal = busInfo["is_live"];
        _isLive = (liveVal != null && liveVal instanceof Lang.Boolean) ? (liveVal as Boolean) : false;

        _busLat = Utils.toFloatSafe(busInfo["bus_lat"]);
        _busLon = Utils.toFloatSafe(busInfo["bus_lon"]);
        _destLat = Utils.toFloatSafe(busInfo["dest_lat"]);
        _destLon = Utils.toFloatSafe(busInfo["dest_lon"]);
        _destName = Utils.toStringSafe(busInfo["dest_name"], "");
        _vehicleRef = Utils.toStringSafe(busInfo["vehicle_ref"], "");

        _centerLat = _station.getLat();
        _centerLon = _station.getLon();

        // Grab last-known user GPS right away so initial center is midpoint between user and bus
        var initInfo = Position.getInfo();
        if (initInfo != null) {
            updateUserPositionFromInfo(initInfo);
        }

        computeInitialViewport();
    }

    public function onLayout(dc as Dc) as Void {
        _screenW = dc.getWidth();
        _screenH = dc.getHeight();
    }

    public function onShow() as Void {
        // Grab last-known position and start continuous live GPS updates for user's position dot
        var info = Position.getInfo();
        if (info != null && updateUserPositionFromInfo(info)) {
            if (!_userZoomedManually) {
                computeInitialViewport();
            } else {
                updateCenterForFocusMode();
            }
        }
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));

        requestTilesForCurrentView();
        if (_routeLats.size() == 0 && !_isFetchingRoute) {
            fetchRoutePolyline();
        }
        if (_stopLats.size() == 0 && !_isFetchingStops && _routeId.length() > 0) {
            fetchRouteStops();
        }
        if (_refreshTimer == null) {
            _refreshTimer = new Timer.Timer();
            // 5s tick updates live ETA countdown & GPS age, and refreshes bus position every 15s
            _refreshTimer.start(method(:onAutoRefreshTick), 5000, true);
        }
    }

    public function onHide() as Void {
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
        if (_refreshTimer != null) {
            _refreshTimer.stop();
            _refreshTimer = null;
        }
        _tileManager.clear();
    }

    public function onPosition(info as Position.Info) as Void {
        var hadUser = (_userLat != null && _userLon != null);
        if (updateUserPositionFromInfo(info)) {
            if (!hadUser && !_userZoomedManually) {
                computeInitialViewport();
                requestTilesForCurrentView();
                WatchUi.requestUpdate();
                return;
            }

            // Keep map camera stationary if user is still comfortably inside the viewport;
            // only redraw if the user's screen dot actually moved by >= 2px.
            var mapCx = _screenW / 2;
            var mapCy = (_screenH * 0.45).toNumber();
            var tileSize = _tileManager.getTileSize();
            var cxf = MapTileManager.lonToTileX(_centerLon, _zoom);
            var cyf = MapTileManager.latToTileY(_centerLat, _zoom);
            var uPt = MapTileManager.projectToScreen(_userLat, _userLon, cxf, cyf, _zoom, mapCx, mapCy, tileSize);

            var dxPrev = uPt[0] - _lastUserScreenX;
            var dyPrev = uPt[1] - _lastUserScreenY;
            if (dxPrev < 0) { dxPrev = -dxPrev; }
            if (dyPrev < 0) { dyPrev = -dyPrev; }
            if (dxPrev < 2 && dyPrev < 2) {
                return;
            }
            _lastUserScreenX = uPt[0];
            _lastUserScreenY = uPt[1];

            // Only pan the map camera if in FOCUS_USER or if user drifted near screen edge
            var edgeMarginX = (_screenW * 0.36).toNumber();
            var edgeMarginY = (_screenH * 0.30).toNumber();
            var offCenterX = uPt[0] - mapCx;
            var offCenterY = uPt[1] - mapCy;
            if (offCenterX < 0) { offCenterX = -offCenterX; }
            if (offCenterY < 0) { offCenterY = -offCenterY; }

            if (_focusMode == FOCUS_USER || offCenterX > edgeMarginX || offCenterY > edgeMarginY) {
                updateCenterForFocusMode();
                requestTilesForCurrentView();
            }
            WatchUi.requestUpdate();
        }
    }

    private function updateUserPositionFromInfo(info as Position.Info) as Boolean {
        if (info.position == null || info.accuracy == Position.QUALITY_NOT_AVAILABLE) {
            return false;
        }
        var coords = info.position.toDegrees();
        if (coords == null || coords.size() < 2) {
            return false;
        }
        var lat = coords[0].toFloat();
        var lon = coords[1].toFloat();
        if (lat > 29.0f && lat < 34.0f && lon > 34.0f && lon < 36.0f) {
            _userLat = lat;
            _userLon = lon;
            return true;
        }
        return false;
    }

    public function onAutoRefreshTick() as Void {
        var watchNow = Time.now().value();

        // Live local ETA countdown and GPS freshness aging between 15s network updates
        if (_etaLocalEpoch != null) {
            var remSec = _etaLocalEpoch - watchNow;
            var etaMins = (remSec > 30) ? ((remSec + 30) / 60).toNumber() : 0;
            if (etaMins < 0) {
                etaMins = 0;
            }
            _etaMin = etaMins;
            _etaLabel = Utils.formatEtaFromSeconds(remSec);
        }
        if (_isLive && _pingLocalEpoch != null) {
            var ageSec = watchNow - _pingLocalEpoch;
            if (ageSec < 0) {
                ageSec = 0;
            }
            if (ageSec > 300) {
                _status = Utils.STATUS_STALE_OR_OFF;
                _statusReason = "Stale";
            } else if (ageSec > 120) {
                _status = Utils.STATUS_STALE_WARN;
                _statusReason = "Delayed";
            } else {
                _status = Utils.STATUS_LIVE_ON_ROUTE;
                _statusReason = "Live";
            }
        }

        // Refresh the currently viewed bus line every 15 seconds
        if (!_isRefreshingBus && (watchNow - _lastBusRefreshEpoch) >= 15) {
            refreshBusPosition();
        } else {
            WatchUi.requestUpdate();
        }
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

    private function computeInitialViewport() as Void {
        var stLat = _station.getLat();
        var stLon = _station.getLon();
        var anchorLat = (_userLat != null) ? _userLat : stLat;
        var anchorLon = (_userLon != null) ? _userLon : stLon;
        var tileSize = computeTileSize();
        var spanPx = (_screenW * 0.56).toNumber();

        if (_busLat != null && _busLon != null) {
            // Center on the midpoint between the user (or station if GPS unavailable) and the bus
            _centerLat = ((_busLat + anchorLat) / 2.0f).toFloat();
            _centerLon = ((_busLon + anchorLon) / 2.0f).toFloat();
            _zoom = MapTileManager.computeOptimalZoom(
                _busLat, _busLon, anchorLat, anchorLon,
                spanPx, tileSize, MIN_ZOOM, 16
            );
        } else if (_destLat != null && _destLon != null) {
            _centerLat = ((anchorLat + _destLat) / 2.0f).toFloat();
            _centerLon = ((anchorLon + _destLon) / 2.0f).toFloat();
            _zoom = MapTileManager.computeOptimalZoom(
                anchorLat, anchorLon, _destLat, _destLon,
                spanPx, tileSize, MIN_ZOOM, 15
            );
        } else {
            _centerLat = anchorLat;
            _centerLon = anchorLon;
            _zoom = 15;
        }
    }

    private function updateCenterForFocusMode() as Void {
        var stLat = _station.getLat();
        var stLon = _station.getLon();
        var anchorLat = (_userLat != null) ? _userLat : stLat;
        var anchorLon = (_userLon != null) ? _userLon : stLon;

        if (_focusMode == FOCUS_BUS && _busLat != null && _busLon != null) {
            _centerLat = _busLat;
            _centerLon = _busLon;
        } else if (_focusMode == FOCUS_STOP) {
            _centerLat = stLat;
            _centerLon = stLon;
        } else if (_focusMode == FOCUS_USER && _userLat != null && _userLon != null) {
            _centerLat = _userLat;
            _centerLon = _userLon;
        } else {
            // FOCUS_FIT: midpoint between user and bus
            if (_busLat != null && _busLon != null) {
                _centerLat = ((_busLat + anchorLat) / 2.0f).toFloat();
                _centerLon = ((_busLon + anchorLon) / 2.0f).toFloat();
            } else if (_destLat != null && _destLon != null) {
                _centerLat = ((anchorLat + _destLat) / 2.0f).toFloat();
                _centerLon = ((anchorLon + _destLon) / 2.0f).toFloat();
            } else {
                _centerLat = anchorLat;
                _centerLon = anchorLon;
            }
        }
    }

    private function requestTilesForCurrentView() as Void {
        _tileManager.updateForCenter(_centerLat, _centerLon, _zoom, computeTileSize());
    }

    public function zoomIn() as Void {
        if (_zoom < MAX_ZOOM) {
            _zoom++;
            _userZoomedManually = true;
            requestTilesForCurrentView();
            WatchUi.requestUpdate();
        }
    }

    public function zoomOut() as Void {
        if (_zoom > MIN_ZOOM) {
            _zoom--;
            _userZoomedManually = true;
            requestTilesForCurrentView();
            WatchUi.requestUpdate();
        }
    }

    public function cycleFocusMode() as Void {
        _focusMode = (_focusMode + 1) % 4;
        if (_focusMode == FOCUS_BUS && (_busLat == null || _busLon == null)) {
            _focusMode = FOCUS_STOP;
        }
        if (_focusMode == FOCUS_USER && (_userLat == null || _userLon == null)) {
            _focusMode = FOCUS_FIT;
        }
        updateCenterForFocusMode();
        requestTilesForCurrentView();
        WatchUi.requestUpdate();
    }

    public function handleTap(clickX as Number, clickY as Number) as Boolean {
        var zoomHit = MapTileManager.hitTestZoomButtons(clickX, clickY, _screenW, _screenH);
        if (zoomHit == 1) {
            zoomIn();
            return true;
        } else if (zoomHit == -1) {
            zoomOut();
            return true;
        }
        return false;
    }

    // Fetch full-resolution road-following route geometry from OSRM.
    // Once ordered GTFS stops are available, traces through the actual bus route stops!
    private function fetchRoutePolyline() as Void {
        var waypoints = [] as Array<Array<Float>>;

        if (_allStopLats.size() >= 2) {
            // Sample up to 16 evenly spaced stops along the actual GTFS route (always keeping first & last)
            var totalStops = _allStopLats.size();
            var maxWaypoints = 16;
            if (totalStops <= maxWaypoints) {
                for (var i = 0; i < totalStops; i++) {
                    waypoints.add([_allStopLats[i], _allStopLons[i]]);
                }
            } else {
                var step = (totalStops - 1).toFloat() / (maxWaypoints - 1).toFloat();
                for (var i = 0; i < maxWaypoints; i++) {
                    var idx = ((i * step) + 0.5f).toNumber();
                    if (idx >= totalStops) {
                        idx = totalStops - 1;
                    }
                    waypoints.add([_allStopLats[idx], _allStopLons[idx]]);
                }
            }
            _hasFullStopRoute = true;
        } else {
            var stLat = _station.getLat();
            var stLon = _station.getLon();

            if (_busLat != null && _busLon != null) {
                waypoints.add([_busLat, _busLon]);
                waypoints.add([stLat, stLon]);
                if (_destLat != null && _destLon != null) {
                    var destDist = Utils.calculateDistanceMeters(stLat, stLon, _destLat, _destLon);
                    if (destDist > 80) {
                        waypoints.add([_destLat, _destLon]);
                    }
                }
                _lastRouteBusLat = _busLat;
                _lastRouteBusLon = _busLon;
            } else if (_destLat != null && _destLon != null) {
                waypoints.add([stLat, stLon]);
                waypoints.add([_destLat, _destLon]);
            } else {
                return;
            }
        }

        _isFetchingRoute = true;
        api_requester.get_route_geometry(
            waypoints,
            method(:onRouteGeometryLoaded),
            method(:onRouteGeometryError)
        );
    }

    public function onRouteGeometryLoaded(data as Object) as Void {
        _isFetchingRoute = false;
        if (data == null || !(data instanceof Lang.Dictionary)) {
            return;
        }
        var resp = data as Dictionary;
        var routesObj = resp["routes"];
        if (routesObj == null || !(routesObj instanceof Lang.Array)) {
            return;
        }
        var routes = routesObj as Array;
        if (routes.size() == 0 || !(routes[0] instanceof Lang.Dictionary)) {
            return;
        }
        var firstRoute = routes[0] as Dictionary;
        var geomObj = firstRoute["geometry"];
        if (geomObj == null) {
            return;
        }

        var lats = [] as Array<Float>;
        var lons = [] as Array<Float>;

        if (geomObj instanceof Lang.String) {
            // Decode full-resolution Google Encoded Polyline (keeps all road curves!)
            var decoded = Utils.decodePolyline(geomObj as String, 240);
            lats = decoded[0];
            lons = decoded[1];
        } else if (geomObj instanceof Lang.Dictionary) {
            var geom = geomObj as Dictionary;
            var coordsObj = geom["coordinates"];
            if (coordsObj != null && coordsObj instanceof Lang.Array) {
                var coords = coordsObj as Array;
                for (var i = 0; i < coords.size(); i++) {
                    var ptObj = coords[i];
                    if (ptObj != null && ptObj instanceof Lang.Array) {
                        var pt = ptObj as Array;
                        if (pt.size() >= 2) {
                            var lon = Utils.toFloatSafe(pt[0]);
                            var lat = Utils.toFloatSafe(pt[1]);
                            if (lat != null && lon != null) {
                                lats.add(lat);
                                lons.add(lon);
                            }
                        }
                    }
                }
            }
        }

        if (lats.size() >= 2) {
            _routeLats = lats;
            _routeLons = lons;
            WatchUi.requestUpdate();
        }
    }

    public function onRouteGeometryError(statusCode as Number, errorMsg as String) as Void {
        _isFetchingRoute = false;
        WatchUi.requestUpdate();
    }

    // Fetch all stops along the bus's GTFS route via Open Bus Stride API (paginated in 10-stop chunks)
    private function fetchRouteStops() as Void {
        if (_routeId.length() == 0) {
            return;
        }
        _isFetchingStops = true;
        var now = Time.now();
        var yesterday = now.subtract(new Time.Duration(86400));
        var dateFromIso = Utils.formatDateISO(yesterday);
        var dateToIso = Utils.formatDateISO(now);
        api_requester.get_stride_route_by_line_ref(
            _routeId,
            dateFromIso,
            dateToIso,
            method(:onStrideRouteLoaded),
            method(:onStrideStopsError)
        );
    }

    public function onStrideRouteLoaded(data as Object) as Void {
        if (data == null || !(data instanceof Lang.Array)) {
            _isFetchingStops = false;
            return;
        }
        var arr = data as Array;
        if (arr.size() == 0 || !(arr[0] instanceof Lang.Dictionary)) {
            _isFetchingStops = false;
            return;
        }
        var routeDict = arr[0] as Dictionary;
        var idObj = routeDict["id"];
        if (idObj == null || !(idObj instanceof Lang.Number)) {
            _isFetchingStops = false;
            return;
        }
        api_requester.get_stride_ride_for_route(
            idObj as Number,
            method(:onStrideRideLoaded),
            method(:onStrideStopsError)
        );
    }

    public function onStrideRideLoaded(data as Object) as Void {
        if (data == null || !(data instanceof Lang.Array)) {
            _isFetchingStops = false;
            return;
        }
        var arr = data as Array;
        if (arr.size() == 0 || !(arr[0] instanceof Lang.Dictionary)) {
            _isFetchingStops = false;
            return;
        }
        var rideDict = arr[0] as Dictionary;
        var idObj = rideDict["id"];
        var startStr = Utils.toStringSafe(rideDict["start_time"], "");
        var endStr = Utils.toStringSafe(rideDict["end_time"], "");
        if (idObj == null || !(idObj instanceof Lang.Number) || startStr.length() == 0 || endStr.length() == 0) {
            _isFetchingStops = false;
            return;
        }
        _stopsRideId = idObj as Number;
        _stopsStartTime = startStr;
        _stopsEndTime = endStr;
        _stopsOffset = 0;
        _stopLats = [];
        _stopLons = [];
        _allStopLats = [];
        _allStopLons = [];
        fetchNextStopsPage();
    }

    private function fetchNextStopsPage() as Void {
        if (_stopsRideId < 0 || _stopsOffset >= 60) {
            _isFetchingStops = false;
            return;
        }
        api_requester.get_stride_ride_stops(
            _stopsRideId,
            _stopsStartTime,
            _stopsEndTime,
            _stopsOffset,
            method(:onStrideStopsLoaded),
            method(:onStrideStopsError)
        );
    }

    public function onStrideStopsLoaded(data as Object) as Void {
        if (data == null || !(data instanceof Lang.Array)) {
            _isFetchingStops = false;
            return;
        }
        var arr = data as Array;
        var myCode = _station.getStationCode();
        var addedAny = false;

        for (var i = 0; i < arr.size(); i++) {
            var itemObj = arr[i];
            if (itemObj != null && itemObj instanceof Lang.Dictionary) {
                var item = itemObj as Dictionary;
                var stopCode = Utils.toStringSafe(item["gtfs_stop__code"], "");
                var sLat = Utils.toFloatSafe(item["gtfs_stop__lat"]);
                var sLon = Utils.toFloatSafe(item["gtfs_stop__lon"]);
                if (sLat != null && sLon != null) {
                    _allStopLats.add(sLat);
                    _allStopLons.add(sLon);
                    if (!myCode.equals(stopCode)) {
                        _stopLats.add(sLat);
                        _stopLons.add(sLon);
                    }
                    addedAny = true;
                }
            }
        }

        if (addedAny) {
            WatchUi.requestUpdate();
        }

        if (arr.size() >= 10 && _stopsOffset + 10 < 60) {
            _stopsOffset += 10;
            fetchNextStopsPage();
        } else {
            _isFetchingStops = false;
            // Now that we have the actual ordered GTFS stops, trace the full road-following route through them!
            if (_allStopLats.size() >= 2 && !_isFetchingRoute) {
                fetchRoutePolyline();
            }
        }
    }

    public function onStrideStopsError(statusCode as Number, errorMsg as String) as Void {
        _isFetchingStops = false;
    }

    // Refresh live position & ETA for this bus line from curlbus.app
    public function refreshBusPosition() as Void {
        _isRefreshingBus = true;
        WatchUi.requestUpdate();

        api_requester.get_station_arrivals(
            _station.getStationCode(),
            method(:onBusRefreshLoaded),
            method(:onBusRefreshError)
        );
    }

    public function onBusRefreshLoaded(data as Object) as Void {
        _isRefreshingBus = false;
        if (data == null || !(data instanceof Lang.Dictionary)) {
            WatchUi.requestUpdate();
            return;
        }

        var resp = data as Dictionary;
        var visitsContainer = resp["visits"];
        if (visitsContainer == null || !(visitsContainer instanceof Lang.Dictionary)) {
            WatchUi.requestUpdate();
            return;
        }
        var vDict = visitsContainer as Dictionary;
        var stopVisitsObj = vDict[_station.getStationCode()];
        if (stopVisitsObj == null || !(stopVisitsObj instanceof Lang.Array)) {
            WatchUi.requestUpdate();
            return;
        }
        var visitsList = stopVisitsObj as Array<Dictionary>;

        var nowEpoch = Time.now().value();
        var respEpoch = Utils.parseIsoToEpoch(Utils.toStringSafe(resp["timestamp"], ""));
        if (respEpoch != null) {
            nowEpoch = respEpoch;
        }

        // Find matching bus: prioritize exact vehicle_ref, else matching route name with closest ETA
        var matched = null as Dictionary?;
        var bestEtaDiff = 999999;

        for (var i = 0; i < visitsList.size(); i++) {
            var item = visitsList[i];
            var vRef = Utils.toStringSafe(item["vehicle_ref"], "");
            if (_vehicleRef.length() > 0 && _vehicleRef.equals(vRef)) {
                matched = item;
                break;
            }
            var rawRoute = Utils.toStringSafe(item["line_name"], "?");
            var route = Utils.ensureAsciiStationName(rawRoute, "?");
            if (_routeNum.equals(route)) {
                var etaEpoch = Utils.parseIsoToEpoch(Utils.toStringSafe(item["eta"], ""));
                var etaMin = (etaEpoch != null) ? ((etaEpoch - nowEpoch) / 60).toNumber() : 0;
                if (etaMin < 0) {
                    etaMin = 0;
                }
                var diff = etaMin - _etaMin;
                if (diff < 0) {
                    diff = -diff;
                }
                if (diff < bestEtaDiff) {
                    bestEtaDiff = diff;
                    matched = item;
                }
            }
        }

        if (matched != null) {
            var locObj = matched["location"];
            if (locObj != null && locObj instanceof Lang.Dictionary) {
                var locDict = locObj as Dictionary;
                var newLat = Utils.toFloatSafe(locDict["lat"]);
                var newLon = Utils.toFloatSafe(locDict["lon"]);
                if (newLat != null && newLon != null) {
                    _busLat = newLat;
                    _busLon = newLon;
                    _isLive = true;
                }
            }

            var watchNow = Time.now().value();
            _lastBusRefreshEpoch = watchNow;

            var etaEpoch = Utils.parseIsoToEpoch(Utils.toStringSafe(matched["eta"], ""));
            if (etaEpoch != null) {
                var remSec = etaEpoch - nowEpoch;
                if (remSec < 0) {
                    remSec = 0;
                }
                _etaLocalEpoch = watchNow + remSec;
                var newEta = (remSec > 30) ? ((remSec + 30) / 60).toNumber() : 0;
                _etaMin = newEta;
                _etaLabel = Utils.formatEtaFromSeconds(remSec);
            }

            var pingEpoch = Utils.parseIsoToEpoch(Utils.toStringSafe(matched["timestamp"], ""));
            if (_isLive) {
                var ageSec = (pingEpoch != null) ? (nowEpoch - pingEpoch) : 0;
                if (ageSec < 0) {
                    ageSec = 0;
                }
                _pingLocalEpoch = watchNow - ageSec;
                if (ageSec > 300) {
                    _status = Utils.STATUS_STALE_OR_OFF;
                    _statusReason = "Stale";
                } else if (ageSec > 120) {
                    _status = Utils.STATUS_STALE_WARN;
                    _statusReason = "Delayed";
                } else {
                    _status = Utils.STATUS_LIVE_ON_ROUTE;
                    _statusReason = "Live";
                }
            }

            // Keep the map camera & tiles stationary when the bus is still comfortably inside the viewport!
            // Only recenter/re-fetch tiles if the bus drifted near the screen edge or focus is locked to Bus.
            var shouldRecenter = (_focusMode == FOCUS_BUS);
            if (!shouldRecenter && _busLat != null && _busLon != null) {
                var mapCx = _screenW / 2;
                var mapCy = (_screenH * 0.45).toNumber();
                var tileSize = _tileManager.getTileSize();
                var cxf = MapTileManager.lonToTileX(_centerLon, _zoom);
                var cyf = MapTileManager.latToTileY(_centerLat, _zoom);
                var bPt = MapTileManager.projectToScreen(_busLat, _busLon, cxf, cyf, _zoom, mapCx, mapCy, tileSize);
                var offX = bPt[0] - mapCx;
                var offY = bPt[1] - mapCy;
                if (offX < 0) { offX = -offX; }
                if (offY < 0) { offY = -offY; }
                if (offX > (_screenW * 0.36).toNumber() || offY > (_screenH * 0.28).toNumber()) {
                    shouldRecenter = true;
                }
            }
            if (shouldRecenter) {
                updateCenterForFocusMode();
                requestTilesForCurrentView();
            }

            // Re-fetch route polyline if bus moved > 120m and we don't already have the full stop-based route
            if (!_hasFullStopRoute && _busLat != null && _busLon != null && !_isFetchingRoute) {
                var shouldRefetch = (_lastRouteBusLat == null || _lastRouteBusLon == null);
                if (!shouldRefetch && _lastRouteBusLat != null && _lastRouteBusLon != null) {
                    var moved = Utils.calculateDistanceMeters(_lastRouteBusLat, _lastRouteBusLon, _busLat, _busLon);
                    if (moved > 120) {
                        shouldRefetch = true;
                    }
                }
                if (shouldRefetch) {
                    fetchRoutePolyline();
                }
            }
        }

        WatchUi.requestUpdate();
    }

    public function onBusRefreshError(statusCode as Number, errorMsg as String) as Void {
        _isRefreshingBus = false;
        WatchUi.requestUpdate();
    }

    private function getStatusColor() as Number {
        if (_status == Utils.STATUS_LIVE_ON_ROUTE) {
            return Graphics.COLOR_GREEN;
        } else if (_status == Utils.STATUS_STALE_WARN) {
            return Graphics.COLOR_ORANGE;
        } else if (_status == Utils.STATUS_STALE_OR_OFF) {
            return Graphics.COLOR_RED;
        }
        return Graphics.COLOR_LT_GRAY;
    }

    public function onUpdate(dc as Dc) as Void {
        _screenW = dc.getWidth();
        _screenH = dc.getHeight();
        var w = _screenW;
        var h = _screenH;

        dc.setColor(0x0B1A26, 0x0B1A26);
        dc.clear();

        var mapCx = w / 2;
        var mapCy = (h * 0.45).toNumber();
        var tileSize = _tileManager.getTileSize();
        var centerXFloat = MapTileManager.lonToTileX(_centerLon, _zoom);
        var centerYFloat = MapTileManager.latToTileY(_centerLat, _zoom);

        // 1. Road map tiles (with subtle fallback grid underneath)
        drawFallbackGrid(dc, w, h, mapCx, mapCy);
        _tileManager.drawTiles(dc, _centerLat, _centerLon, _zoom, mapCx, mapCy);

        // 2. Route polyline
        drawRoutePolyline(dc, centerXFloat, centerYFloat, mapCx, mapCy, tileSize);

        // 2b. Bus stops along the route
        drawRouteStops(dc, w, h, centerXFloat, centerYFloat, mapCx, mapCy, tileSize);

        // 3. Destination pin (if available)
        if (_destLat != null && _destLon != null) {
            var dPt = MapTileManager.projectToScreen(_destLat, _destLon, centerXFloat, centerYFloat, _zoom, mapCx, mapCy, tileSize);
            drawDestinationPin(dc, dPt[0], dPt[1]);
        }

        // 4. User's Station pin
        var sPt = MapTileManager.projectToScreen(_station.getLat(), _station.getLon(), centerXFloat, centerYFloat, _zoom, mapCx, mapCy, tileSize);
        drawStationPin(dc, sPt[0], sPt[1]);

        // 4b. User's live GPS position dot
        if (_userLat != null && _userLon != null) {
            var uPt = MapTileManager.projectToScreen(_userLat, _userLon, centerXFloat, centerYFloat, _zoom, mapCx, mapCy, tileSize);
            drawUserDot(dc, uPt[0], uPt[1]);
        }

        // 5. Live Bus position marker (on top)
        if (_busLat != null && _busLon != null) {
            var bPt = MapTileManager.projectToScreen(_busLat, _busLon, centerXFloat, centerYFloat, _zoom, mapCx, mapCy, tileSize);
            drawLiveBusMarker(dc, bPt[0], bPt[1]);
        }

        // 6. Scale bar, Zoom buttons, Top Header, and Bottom HUD
        MapTileManager.drawScaleBar(dc, (w * 0.10).toNumber(), (h * 0.72).toNumber(), _centerLat, _zoom, tileSize);
        MapTileManager.drawZoomButtons(dc, w, h, _zoom, MIN_ZOOM, MAX_ZOOM, false);
        drawTopHeader(dc, w, h);
        drawBottomHUD(dc, w, h);
    }

    private function drawFallbackGrid(dc as Dc, w as Number, h as Number, cx as Number, cy as Number) as Void {
        dc.setColor(0x13293D, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(0, cy, w, cy);
        dc.drawLine(cx, 0, cx, h);
        dc.drawCircle(cx, cy, (w * 0.25).toNumber());
        dc.drawCircle(cx, cy, (w * 0.42).toNumber());
    }

    private function ensureScreenGeometryCache(
        centerXFloat as Double,
        centerYFloat as Double,
        mapCx as Number,
        mapCy as Number,
        tileSize as Number
    ) as Void {
        var rCount = (_routeLats.size() >= 2) ? _routeLats.size() : _allStopLats.size();
        var sCount = _stopLats.size();
        if (_cacheZoom == _zoom &&
            _cacheCenterLat == _centerLat &&
            _cacheCenterLon == _centerLon &&
            _cacheRouteCount == rCount &&
            _cacheStopCount == sCount &&
            _cacheTileSize == tileSize) {
            return;
        }

        _cacheZoom = _zoom;
        _cacheCenterLat = _centerLat;
        _cacheCenterLon = _centerLon;
        _cacheRouteCount = rCount;
        _cacheStopCount = sCount;
        _cacheTileSize = tileSize;

        // 1. Pre-project and pixel-deduplicate route polyline vertices
        _cachedRouteX = [];
        _cachedRouteY = [];
        var srcLats = (_routeLats.size() >= 2) ? _routeLats : _allStopLats;
        var srcLons = (_routeLats.size() >= 2) ? _routeLons : _allStopLons;

        if (srcLats.size() >= 2) {
            var lastX = -99999;
            var lastY = -99999;
            var n = srcLats.size();
            for (var i = 0; i < n; i++) {
                var pt = MapTileManager.projectToScreen(
                    srcLats[i], srcLons[i],
                    centerXFloat, centerYFloat, _zoom, mapCx, mapCy, tileSize
                );
                var sx = pt[0];
                var sy = pt[1];
                // Keep first & last points, and drop points within 2px of previous vertex for fast smooth drawing
                if (i == 0 || i == n - 1) {
                    _cachedRouteX.add(sx);
                    _cachedRouteY.add(sy);
                    lastX = sx;
                    lastY = sy;
                } else {
                    var dx = sx - lastX;
                    var dy = sy - lastY;
                    if (dx < 0) { dx = -dx; }
                    if (dy < 0) { dy = -dy; }
                    if (dx >= 2 || dy >= 2) {
                        _cachedRouteX.add(sx);
                        _cachedRouteY.add(sy);
                        lastX = sx;
                        lastY = sy;
                    }
                }
            }
        }

        // 2. Pre-project visible route stop dots
        _cachedStopX = [];
        _cachedStopY = [];
        var w = _screenW;
        var h = _screenH;
        for (var i = 0; i < _stopLats.size(); i++) {
            var pt = MapTileManager.projectToScreen(
                _stopLats[i], _stopLons[i],
                centerXFloat, centerYFloat, _zoom, mapCx, mapCy, tileSize
            );
            if (pt[0] >= -6 && pt[0] <= w + 6 && pt[1] >= -6 && pt[1] <= h + 6) {
                _cachedStopX.add(pt[0]);
                _cachedStopY.add(pt[1]);
            }
        }
    }

    private function drawRoutePolyline(
        dc as Dc,
        centerXFloat as Double,
        centerYFloat as Double,
        mapCx as Number,
        mapCy as Number,
        tileSize as Number
    ) as Void {
        ensureScreenGeometryCache(centerXFloat, centerYFloat, mapCx, mapCy, tileSize);

        var xs = _cachedRouteX;
        var ys = _cachedRouteY;

        if (xs.size() < 2) {
            // Initial fallback before stops or OSRM return
            xs = [] as Array<Number>;
            ys = [] as Array<Number>;
            if (_busLat != null && _busLon != null) {
                var bp = MapTileManager.projectToScreen(_busLat, _busLon, centerXFloat, centerYFloat, _zoom, mapCx, mapCy, tileSize);
                xs.add(bp[0]);
                ys.add(bp[1]);
            }
            var sp = MapTileManager.projectToScreen(_station.getLat(), _station.getLon(), centerXFloat, centerYFloat, _zoom, mapCx, mapCy, tileSize);
            xs.add(sp[0]);
            ys.add(sp[1]);
            if (_destLat != null && _destLon != null) {
                var dp = MapTileManager.projectToScreen(_destLat, _destLon, centerXFloat, centerYFloat, _zoom, mapCx, mapCy, tileSize);
                xs.add(dp[0]);
                ys.add(dp[1]);
            }
        }

        var count = xs.size();
        if (count < 2) {
            return;
        }

        var w = _screenW;
        var h = _screenH;

        // Dark outer casing for crisp visibility over bright street tiles (skip off-screen segments)
        dc.setColor(0x0A1926, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(6);
        for (var i = 0; i < count - 1; i++) {
            var x1 = xs[i];
            var y1 = ys[i];
            var x2 = xs[i + 1];
            var y2 = ys[i + 1];
            if ((x1 < -20 && x2 < -20) || (x1 > w + 20 && x2 > w + 20) ||
                (y1 < -20 && y2 < -20) || (y1 > h + 20 && y2 > h + 20)) {
                continue;
            }
            dc.drawLine(x1, y1, x2, y2);
        }

        // Bright route line inside casing
        dc.setColor(0x0088FF, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(3);
        for (var i = 0; i < count - 1; i++) {
            var x1 = xs[i];
            var y1 = ys[i];
            var x2 = xs[i + 1];
            var y2 = ys[i + 1];
            if ((x1 < -20 && x2 < -20) || (x1 > w + 20 && x2 > w + 20) ||
                (y1 < -20 && y2 < -20) || (y1 > h + 20 && y2 > h + 20)) {
                continue;
            }
            dc.drawLine(x1, y1, x2, y2);
        }
        dc.setPenWidth(1);
    }

    private function drawRouteStops(
        dc as Dc,
        w as Number,
        h as Number,
        centerXFloat as Double,
        centerYFloat as Double,
        mapCx as Number,
        mapCy as Number,
        tileSize as Number
    ) as Void {
        if (_cachedStopX.size() == 0) {
            return;
        }
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        for (var i = 0; i < _cachedStopX.size(); i++) {
            dc.fillCircle(_cachedStopX[i], _cachedStopY[i], 3);
        }
    }

    private function drawStationPin(dc as Dc, x as Number, y as Number) as Void {
        // Dark border + gold/blue stop badge with 'S'
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.fillCircle(x, y, 9);
        dc.setColor(0xFFCC00, 0xFFCC00);
        dc.fillCircle(x, y, 7);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, Graphics.FONT_XTINY, "S", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    private function drawUserDot(dc as Dc, x as Number, y as Number) as Void {
        dc.setColor(0x00AAFF, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(x, y, 9);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawCircle(x, y, 6);
        dc.setPenWidth(1);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
        dc.fillCircle(x, y, 5);
        dc.setColor(0x0088FF, 0x0088FF);
        dc.fillCircle(x, y, 3);
    }

    private function drawDestinationPin(dc as Dc, x as Number, y as Number) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.fillCircle(x, y, 7);
        dc.setColor(0xFF4444, 0xFF4444);
        dc.fillCircle(x, y, 5);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
        dc.fillCircle(x, y, 2);
    }

    private function drawLiveBusMarker(dc as Dc, x as Number, y as Number) as Void {
        var statusColor = getStatusColor();

        // Outer contrast halo
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(3);
        dc.drawCircle(x, y, 13);
        dc.setColor(statusColor, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawCircle(x, y, 12);
        dc.setPenWidth(1);

        // Bus body
        dc.setColor(statusColor, statusColor);
        dc.fillRoundedRectangle(x - 8, y - 8, 16, 15, 4);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawRoundedRectangle(x - 8, y - 8, 16, 15, 4);

        // Windshield
        dc.setColor(0x0A1926, 0x0A1926);
        dc.fillRectangle(x - 5, y - 5, 10, 5);

        // Headlights
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
        dc.fillCircle(x - 4, y + 3, 1);
        dc.fillCircle(x + 4, y + 3, 1);

        // Line number pill above the bus marker
        var pillW = 28;
        if (_routeNum.length() > 3) {
            pillW = 36;
        }
        var pillX = x - (pillW / 2);
        var pillY = y - 24;
        dc.setColor(0x0E1E2B, 0x0E1E2B);
        dc.fillRoundedRectangle(pillX, pillY, pillW, 13, 4);
        dc.setColor(statusColor, Graphics.COLOR_TRANSPARENT);
        dc.drawRoundedRectangle(pillX, pillY, pillW, 13, 4);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, pillY + 6, Graphics.FONT_XTINY, _routeNum, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    private function drawTopHeader(dc as Dc, w as Number, h as Number) as Void {
        var barW = (w * 0.64).toNumber();
        var barH = (h * 0.13).toNumber();
        var barX = (w - barW) / 2;
        var barY = (h * 0.03).toNumber();

        dc.setColor(0x0E1E2B, 0x0E1E2B);
        dc.fillRoundedRectangle(barX, barY, barW, barH, 8);
        dc.setColor(getStatusColor(), Graphics.COLOR_TRANSPARENT);
        dc.drawRoundedRectangle(barX, barY, barW, barH, 8);

        var headerStr = "Line " + _routeNum + " | " + _etaLabel;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            barY + (barH / 2),
            Graphics.FONT_XTINY,
            headerStr,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    private function drawBottomHUD(dc as Dc, w as Number, h as Number) as Void {
        var cardY = (h * 0.77).toNumber();
        var cardH = (h * 0.21).toNumber();
        var cardX = (w * 0.14).toNumber();
        var cardW = (w * 0.72).toNumber();

        dc.setColor(0x0E1E2B, 0x0E1E2B);
        dc.fillRoundedRectangle(cardX, cardY, cardW, cardH, 8);
        dc.setColor(getStatusColor(), Graphics.COLOR_TRANSPARENT);
        dc.drawRoundedRectangle(cardX, cardY, cardW, cardH, 8);

        // Line 1: Distance from bus to stop + last GPS position update age (or Scheduled)
        var line1 = "";
        if (_isRefreshingBus) {
            line1 = "Updating bus GPS...";
        } else if (_busLat != null && _busLon != null) {
            var distM = Utils.calculateDistanceMeters(_busLat, _busLon, _station.getLat(), _station.getLon());
            var distStr = "";
            if (distM >= 1000) {
                var kmTenths = ((distM + 50) / 100).toNumber();
                distStr = (kmTenths / 10).toString() + "." + (kmTenths % 10).toString() + "km";
            } else {
                distStr = distM.toString() + "m";
            }
            if (_pingLocalEpoch != null) {
                var ageStr = Utils.formatAgeShort(Time.now().value() - _pingLocalEpoch);
                line1 = distStr + " | GPS " + ageStr + " ago";
            } else {
                line1 = distStr + " | " + _statusReason;
            }
        } else {
            line1 = "Scheduled (no live GPS)";
        }

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            cardY + 2,
            Graphics.FONT_XTINY,
            line1,
            Graphics.TEXT_JUSTIFY_CENTER
        );

        // Line 2: Destination name or focus mode hint
        var line2 = "";
        if (_destName.length() > 0) {
            line2 = "To: " + _destName;
            if (line2.length() > 18) {
                line2 = line2.substring(0, 16) + "..";
            }
        } else {
            var focusLabel = (_focusMode == FOCUS_BUS) ? "Focus: Bus" : ((_focusMode == FOCUS_STOP) ? "Focus: Stop" : "Focus: Fit");
            line2 = focusLabel + " | Z" + _zoom.toString();
        }

        dc.setColor(0x00CCFF, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            cardY + (cardH / 2),
            Graphics.FONT_XTINY,
            line2,
            Graphics.TEXT_JUSTIFY_CENTER
        );
    }
}

class BusRouteMapDelegate extends WatchUi.BehaviorDelegate {

    private var _view as BusRouteMapView;

    public function initialize(view as BusRouteMapView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    public function onPreviousPage() as Boolean {
        _view.zoomIn();
        return true;
    }

    public function onPrevPage() as Boolean {
        _view.zoomIn();
        return true;
    }

    public function onNextPage() as Boolean {
        _view.zoomOut();
        return true;
    }

    public function onSelect() as Boolean {
        _view.refreshBusPosition();
        return true;
    }

    public function onMenu() as Boolean {
        _view.cycleFocusMode();
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

    public function onBack() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}
