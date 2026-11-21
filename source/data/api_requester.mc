import Toybox.Lang;
import Toybox.Communications;
import Toybox.System;
import Toybox.Time;

class ApiRequester {

    private var _baseUrl as String;

    public function initialize(baseUrl as String) {
        _baseUrl = baseUrl;
    }

    // Fetch latest SIRI stop ID for a station code
    public function get_station_siri_id(
        station_code as String,
        onSuccess as Method(data as Object) as Void,
        onError as Method(statusCode as Number, errorMsg as String) as Void
    ) as Void {
        var request = new GenericHttpRequest(onSuccess, onError);
        var params = {
            "get_count" => "false",
            "codes" => station_code,
            "order_by" => "id desc",
            "limit" => "1"
        };
        request.send(
            _baseUrl + "/siri_stops/list",
            params,
            Communications.HTTP_REQUEST_METHOD_GET,
            null
        );
    }

    // Fetch station metadata (name, lat, lon) from GTFS stops by station code (singular "code")
    public function get_gtfs_stop_info(
        station_code as String,
        onSuccess as Method(data as Object) as Void,
        onError as Method(statusCode as Number, errorMsg as String) as Void
    ) as Void {
        var request = new GenericHttpRequest(onSuccess, onError);
        var params = {
            "get_count" => "false",
            "code" => station_code,
            "limit" => "1"
        };
        request.send(
            _baseUrl + "/gtfs_stops/list",
            params,
            Communications.HTTP_REQUEST_METHOD_GET,
            null
        );
    }

    // Fetch recent & upcoming buses (SIRI + GTFS joined) for a siri_stop_id
    public function get_station_buses(
        siri_stop_id as String,
        onSuccess as Method(data as Object) as Void,
        onError as Method(statusCode as Number, errorMsg as String) as Void
    ) as Void {
        var request = new GenericHttpRequest(onSuccess, onError);
        var params = {
            "limit" => "6",
            "get_count" => "false",
            "siri_stop_ids" => siri_stop_id,
            "order_by" => "id desc"
        };
        request.send(
            _baseUrl + "/siri_ride_stops/list",
            params,
            Communications.HTTP_REQUEST_METHOD_GET,
            null
        );
    }

    // Fallback query without order_by in case the server rejects the order_by column
    public function get_station_buses_fallback(
        siri_stop_id as String,
        onSuccess as Method(data as Object) as Void,
        onError as Method(statusCode as Number, errorMsg as String) as Void
    ) as Void {
        var request = new GenericHttpRequest(onSuccess, onError);
        var params = {
            "limit" => "6",
            "get_count" => "false",
            "siri_stop_ids" => siri_stop_id
        };
        request.send(
            _baseUrl + "/siri_ride_stops/list",
            params,
            Communications.HTTP_REQUEST_METHOD_GET,
            null
        );
    }

    // Fetch nearby stations using GPS coordinates via /siri_ride_stops/list
    // which natively supports gtfs_stop__lat/lon bounding box filters and returns
    // siri_stop_id, gtfs_stop__code, gtfs_stop__name, gtfs_stop__lat, gtfs_stop__lon.
    public function get_nearby_stations(
        lat as Float,
        lon as Float,
        onSuccess as Method(data as Object) as Void,
        onError as Method(statusCode as Number, errorMsg as String) as Void
    ) as Void {
        var request = new GenericHttpRequest(onSuccess, onError);
        var delta = 0.005f; // ~550 meters
        var minLat = (lat - delta).format("%.5f");
        var maxLat = (lat + delta).format("%.5f");
        var minLon = (lon - delta).format("%.5f");
        var maxLon = (lon + delta).format("%.5f");

        var params = {
            "get_count" => "false",
            "gtfs_stop__lat__greater_or_equal" => minLat,
            "gtfs_stop__lat__lower_or_equal" => maxLat,
            "gtfs_stop__lon__greater_or_equal" => minLon,
            "gtfs_stop__lon__lower_or_equal" => maxLon,
            "limit" => "8"
        };

        request.send(
            _baseUrl + "/siri_ride_stops/list",
            params,
            Communications.HTTP_REQUEST_METHOD_GET,
            null
        );
    }
}
