import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Time;
import Toybox.Timer;
import Toybox.WatchUi;

class BusRouteMapView extends WatchUi.View {

    private static const MIN_ZOOM = 10;
    private static const MAX_ZOOM = 17;

    private static const FOCUS_FIT = 0;
    private static const FOCUS_BUS = 1;
    private static const FOCUS_STOP = 2;

    private var _station as Station;
    private var _routeNum as String;
    private var _etaLabel as String;
    private var _etaMin as Number;
    private var _status as Number;
    private var _statusReason as String;
    private var _isLive as Boolean;
    private var _busLat as Float?;
    private var _busLon as Float?;
    private var _destLat as Float?;
    private var _destLon as Float?;
    private var _destName as String;
    private var _vehicleRef as String;

    private var _tileManager as MapTileManager;
    private var _zoom as Number = 14;
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

    private var _refreshTimer as Timer.Timer?;
    private var _screenW as Number = 260;
    private var _screenH as Number = 260;

    public function initialize(station as Station, busInfo as Dictionary) {
        View.initialize();
        _station = station;
        _tileManager = new MapTileManager();

        _routeNum = Utils.toStringSafe(busInfo["route"], "?");
        _etaLabel = Utils.toStringSafe(busInfo["eta_label"], "--");
        var etaVal = busInfo["eta_min"];
        _etaMin = (etaVal != null && etaVal instanceof Lang.Number) ? (etaVal as Number) : 0;
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

        computeInitialViewport();
    }

    public function onLayout(dc as Dc) as Void {
        _screenW = dc.getWidth();
        _screenH = dc.getHeight();
    }

    public function onShow() as Void {
        requestTilesForCurrentView();
        if (_routeLats.size() == 0 && !_isFetchingRoute) {
            fetchRoutePolyline();
        }
        if (_refreshTimer == null) {
            _refreshTimer = new Timer.Timer();
            _refreshTimer.start(method(:onAutoRefreshTick), 20000, true);
        }
    }

    public function onHide() as Void {
        if (_refreshTimer != null) {
            _refreshTimer.stop();
            _refreshTimer = null;
        }
        _tileManager.clear();
    }

    public function onAutoRefreshTick() as Void {
        if (!_isRefreshingBus) {
            refreshBusPosition();
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
        var tileSize = computeTileSize();
        var spanPx = (_screenW * 0.56).toNumber();

        if (_busLat != null && _busLon != null) {
            _centerLat = ((_busLat + stLat) / 2.0f).toFloat();
            _centerLon = ((_busLon + stLon) / 2.0f).toFloat();
            _zoom = MapTileManager.computeOptimalZoom(
                _busLat, _busLon, stLat, stLon,
                spanPx, tileSize, MIN_ZOOM, 16
            );
        } else if (_destLat != null && _destLon != null) {
            _centerLat = ((stLat + _destLat) / 2.0f).toFloat();
            _centerLon = ((stLon + _destLon) / 2.0f).toFloat();
            _zoom = MapTileManager.computeOptimalZoom(
                stLat, stLon, _destLat, _destLon,
                spanPx, tileSize, MIN_ZOOM, 15
            );
        } else {
            _centerLat = stLat;
            _centerLon = stLon;
            _zoom = 15;
        }
    }

    private function updateCenterForFocusMode() as Void {
        var stLat = _station.getLat();
        var stLon = _station.getLon();

        if (_focusMode == FOCUS_BUS && _busLat != null && _busLon != null) {
            _centerLat = _busLat;
            _centerLon = _busLon;
        } else if (_focusMode == FOCUS_STOP) {
            _centerLat = stLat;
            _centerLon = stLon;
        } else {
            // FOCUS_FIT
            if (_busLat != null && _busLon != null) {
                _centerLat = ((_busLat + stLat) / 2.0f).toFloat();
                _centerLon = ((_busLon + stLon) / 2.0f).toFloat();
            } else if (_destLat != null && _destLon != null) {
                _centerLat = ((stLat + _destLat) / 2.0f).toFloat();
                _centerLon = ((stLon + _destLon) / 2.0f).toFloat();
            } else {
                _centerLat = stLat;
                _centerLon = stLon;
            }
        }
    }

    private function requestTilesForCurrentView() as Void {
        _tileManager.updateForCenter(_centerLat, _centerLon, _zoom, computeTileSize());
    }

    public function zoomIn() as Void {
        if (_zoom < MAX_ZOOM) {
            _zoom++;
            requestTilesForCurrentView();
            WatchUi.requestUpdate();
        }
    }

    public function zoomOut() as Void {
        if (_zoom > MIN_ZOOM) {
            _zoom--;
            requestTilesForCurrentView();
            WatchUi.requestUpdate();
        }
    }

    public function cycleFocusMode() as Void {
        if (_busLat != null && _busLon != null) {
            _focusMode = (_focusMode + 1) % 3;
        } else {
            _focusMode = (_focusMode == FOCUS_STOP) ? FOCUS_FIT : FOCUS_STOP;
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

    // Fetch simplified road-following route geometry from OSRM
    private function fetchRoutePolyline() as Void {
        var waypoints = [] as Array<Array<Float>>;
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
        if (geomObj == null || !(geomObj instanceof Lang.Dictionary)) {
            return;
        }
        var geom = geomObj as Dictionary;
        var coordsObj = geom["coordinates"];
        if (coordsObj == null || !(coordsObj instanceof Lang.Array)) {
            return;
        }
        var coords = coordsObj as Array;
        var lats = [] as Array<Float>;
        var lons = [] as Array<Float>;

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

            var etaEpoch = Utils.parseIsoToEpoch(Utils.toStringSafe(matched["eta"], ""));
            if (etaEpoch != null) {
                var newEta = ((etaEpoch - nowEpoch) / 60).toNumber();
                if (newEta < 0) {
                    newEta = 0;
                }
                _etaMin = newEta;
                if (newEta == 0) {
                    _etaLabel = "Now";
                } else if (newEta > 99) {
                    _etaLabel = "99+ min";
                } else {
                    _etaLabel = newEta.toString() + " min";
                }
            }

            var pingEpoch = Utils.parseIsoToEpoch(Utils.toStringSafe(matched["timestamp"], ""));
            if (_isLive) {
                var ageSec = (pingEpoch != null) ? (nowEpoch - pingEpoch) : 0;
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

            updateCenterForFocusMode();
            requestTilesForCurrentView();

            // Re-fetch route polyline if bus moved > 120m since last route fetch
            if (_busLat != null && _busLon != null && !_isFetchingRoute) {
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

        // 3. Destination pin (if available)
        if (_destLat != null && _destLon != null) {
            var dPt = MapTileManager.projectToScreen(_destLat, _destLon, centerXFloat, centerYFloat, _zoom, mapCx, mapCy, tileSize);
            drawDestinationPin(dc, dPt[0], dPt[1]);
        }

        // 4. User's Station pin
        var sPt = MapTileManager.projectToScreen(_station.getLat(), _station.getLon(), centerXFloat, centerYFloat, _zoom, mapCx, mapCy, tileSize);
        drawStationPin(dc, sPt[0], sPt[1]);

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

    private function drawRoutePolyline(
        dc as Dc,
        centerXFloat as Double,
        centerYFloat as Double,
        mapCx as Number,
        mapCy as Number,
        tileSize as Number
    ) as Void {
        var screenPts = [] as Array<Array<Number>>;

        if (_routeLats.size() >= 2) {
            for (var i = 0; i < _routeLats.size(); i++) {
                screenPts.add(MapTileManager.projectToScreen(
                    _routeLats[i], _routeLons[i],
                    centerXFloat, centerYFloat, _zoom, mapCx, mapCy, tileSize
                ));
            }
        } else {
            // Fallback straight segments while OSRM route is loading
            if (_busLat != null && _busLon != null) {
                screenPts.add(MapTileManager.projectToScreen(_busLat, _busLon, centerXFloat, centerYFloat, _zoom, mapCx, mapCy, tileSize));
            }
            screenPts.add(MapTileManager.projectToScreen(_station.getLat(), _station.getLon(), centerXFloat, centerYFloat, _zoom, mapCx, mapCy, tileSize));
            if (_destLat != null && _destLon != null) {
                screenPts.add(MapTileManager.projectToScreen(_destLat, _destLon, centerXFloat, centerYFloat, _zoom, mapCx, mapCy, tileSize));
            }
        }

        if (screenPts.size() < 2) {
            return;
        }

        // Dark outer casing for crisp visibility over bright street tiles
        dc.setColor(0x0A1926, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(6);
        for (var i = 0; i < screenPts.size() - 1; i++) {
            dc.drawLine(screenPts[i][0], screenPts[i][1], screenPts[i + 1][0], screenPts[i + 1][1]);
        }

        // Bright route line inside casing
        dc.setColor(0x0088FF, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(3);
        for (var i = 0; i < screenPts.size() - 1; i++) {
            dc.drawLine(screenPts[i][0], screenPts[i][1], screenPts[i + 1][0], screenPts[i + 1][1]);
        }
        dc.setPenWidth(1);
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

        // Line 1: Distance from bus to stop + status (or Scheduled)
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
            line1 = distStr + " away | " + _statusReason;
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
