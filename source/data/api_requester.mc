import Toybox.Lang;
import Toybox.Communications;
import Toybox.System;

class ApiRequester {

    private var _baseUrl as String;

    public function initialize(baseUrl as String) {
        _baseUrl = baseUrl;
    }

    // Fetch live and scheduled arrivals + station metadata for a stop code in a single fast request (~0.5s)
    // Endpoint: GET https://curlbus.app/<station_code> with Accept: application/json
    public function get_station_arrivals(
        station_code as String,
        onSuccess as Method(data as Object) as Void,
        onError as Method(statusCode as Number, errorMsg as String) as Void
    ) as Void {
        var request = new GenericHttpRequest(onSuccess, onError);
        var headers = {
            "Accept" => "application/json"
        };
        request.send(
            _baseUrl + "/" + station_code,
            null,
            Communications.HTTP_REQUEST_METHOD_GET,
            headers
        );
    }

    // Fetch nearby stations sorted by distance in a single fast request (~0.25s)
    // Endpoint: GET https://curlbus.app/nearby?lat=<lat>&lon=<lon> with Accept: application/json
    public function get_nearby_stations(
        lat as Float,
        lon as Float,
        onSuccess as Method(data as Object) as Void,
        onError as Method(statusCode as Number, errorMsg as String) as Void
    ) as Void {
        var request = new GenericHttpRequest(onSuccess, onError);
        var params = {
            "lat" => lat.format("%.5f"),
            "lon" => lon.format("%.5f")
        };
        var headers = {
            "Accept" => "application/json"
        };
        request.send(
            _baseUrl + "/nearby",
            params,
            Communications.HTTP_REQUEST_METHOD_GET,
            headers
        );
    }

    // Fetch full-resolution road-following route geometry (Google Encoded Polyline) from OSRM
    // waypoints: Array of [lat, lon] Float pairs
    public function get_route_geometry(
        waypoints as Array<Array<Float>>,
        onSuccess as Method(data as Object) as Void,
        onError as Method(statusCode as Number, errorMsg as String) as Void
    ) as Void {
        if (waypoints.size() < 2) {
            return;
        }
        var coordsStr = "";
        for (var i = 0; i < waypoints.size(); i++) {
            if (i > 0) {
                coordsStr += ";";
            }
            var pt = waypoints[i];
            // OSRM expects lon,lat order
            coordsStr += pt[1].format("%.5f") + "," + pt[0].format("%.5f");
        }

        var request = new GenericHttpRequest(onSuccess, onError);
        var params = {
            "overview" => "full",
            "geometries" => "polyline",
            "steps" => "false"
        };
        var headers = {
            "Accept" => "application/json"
        };
        request.send(
            "https://router.project-osrm.org/route/v1/driving/" + coordsStr,
            params,
            Communications.HTTP_REQUEST_METHOD_GET,
            headers
        );
    }

    // Step 1: Look up most recent GTFS route id from curlbus line_ref / route_id via Open Bus Stride
    public function get_stride_route_by_line_ref(
        lineRef as String,
        dateFromIso as String,
        dateToIso as String,
        onSuccess as Method(data as Object) as Void,
        onError as Method(statusCode as Number, errorMsg as String) as Void
    ) as Void {
        var request = new GenericHttpRequest(onSuccess, onError);
        var params = {
            "limit" => "1",
            "line_refs" => lineRef,
            "date_from" => dateFromIso,
            "date_to" => dateToIso,
            "order_by" => "date desc"
        };
        request.send(
            "https://open-bus-stride-api.hasadna.org.il/gtfs_routes/list",
            params,
            Communications.HTTP_REQUEST_METHOD_GET,
            { "Accept" => "application/json" }
        );
    }

    // Step 2: Fetch one scheduled GTFS ride for that route to get its stop sequence
    public function get_stride_ride_for_route(
        gtfsRouteId as Number,
        onSuccess as Method(data as Object) as Void,
        onError as Method(statusCode as Number, errorMsg as String) as Void
    ) as Void {
        var request = new GenericHttpRequest(onSuccess, onError);
        var params = {
            "limit" => "1",
            "gtfs_route_id" => gtfsRouteId.toString()
        };
        request.send(
            "https://open-bus-stride-api.hasadna.org.il/gtfs_rides/list",
            params,
            Communications.HTTP_REQUEST_METHOD_GET,
            { "Accept" => "application/json" }
        );
    }

    // Step 3: Fetch ordered stops (lat/lon) in small 10-stop pages so watch RAM never overflows
    public function get_stride_ride_stops(
        gtfsRideId as Number,
        startTime as String,
        endTime as String,
        offset as Number,
        onSuccess as Method(data as Object) as Void,
        onError as Method(statusCode as Number, errorMsg as String) as Void
    ) as Void {
        var request = new GenericHttpRequest(onSuccess, onError);
        var params = {
            "limit" => "10",
            "offset" => offset.toString(),
            "gtfs_ride_ids" => gtfsRideId.toString(),
            "arrival_time_from" => startTime,
            "arrival_time_to" => endTime,
            "order_by" => "stop_sequence asc"
        };
        request.send(
            "https://open-bus-stride-api.hasadna.org.il/gtfs_ride_stops/list",
            params,
            Communications.HTTP_REQUEST_METHOD_GET,
            { "Accept" => "application/json" }
        );
    }
}
