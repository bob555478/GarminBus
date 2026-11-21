import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;

class GenericHttpRequest {

    private var _onSuccess as Method(data as Object) as Void;
    private var _onError as Method(statusCode as Number, errorMsg as String) as Void;

    function initialize(
        onSuccess as Method(data as Object) as Void,
        onError as Method(statusCode as Number, errorMsg as String) as Void
    ) {
        _onSuccess = onSuccess;
        _onError = onError;
    }

    public function send(
        url as String,
        params as Dictionary or Null,
        httpMethod as Communications.HttpRequestMethod,
        headers as Dictionary or Null
    ) as Void {

        var options = {
            :method => httpMethod,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };

        if (headers != null) {
            options.put(:headers, headers);
        }
        System.println("Sending request to: " + url);
        System.println("Request parameters: " + params);
        Communications.makeWebRequest(
            url,
            params,
            options,
            method(:onReceive)
        );
    }

    public function onReceive(responseCode as Number, data as Null or Dictionary or String) as Void {
        if (responseCode >= 200 && responseCode < 300) {
            if (data != null) {
                System.println("data: " + data);
                _onSuccess.invoke(data);
            } else {
                _onError.invoke(responseCode, "Response body was null");
            }
        } else {
            var errorMsg = parseErrorMessage(responseCode);
            _onError.invoke(responseCode, errorMsg);
        }
    }

    private function parseErrorMessage(code as Number) as String {
        switch (code) {
            case Communications.BLE_ERROR:
                return "Bluetooth connection failed";
            case Communications.BLE_HOST_TIMEOUT:
                return "Phone connection timed out";
            case Communications.BLE_SERVER_TIMEOUT:
                return "Server connection timed out";
            case Communications.NETWORK_REQUEST_TIMED_OUT:
                return "Network request timed out";
            case Communications.NETWORK_RESPONSE_OUT_OF_MEMORY:
                return "Out of memory processing response";
            case Communications.INVALID_HTTP_BODY_IN_NETWORK_RESPONSE:
                return "Invalid response body / JSON format";
            case 401:
                return "Unauthorized (401)";
            case 403:
                return "Forbidden (403)";
            case 404:
                return "Resource not found (404)";
            case 500:
                return "Internal server error (500)";
            default:
                return "HTTP Error: " + code;
        }
    }
}