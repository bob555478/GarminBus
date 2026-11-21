import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class GarminBusApp extends Application.AppBase {

    private var _mainView as BusTimesView?;

    function initialize() {
        AppBase.initialize();
    }

    // onStart() is called on application start up
    function onStart(state as Dictionary?) as Void {
    }

    // onStop() is called when your application is exiting
    function onStop(state as Dictionary?) as Void {
    }

    // Triggered automatically when user saves settings in Garmin Connect on their phone
    function onSettingsChanged() as Void {
        if (_mainView != null) {
            _mainView.reloadFavoritesList();
        }
    }

    // Return the initial view of your application here
    function getInitialView() as [Views] or [Views, InputDelegates] {
        _mainView = new BusTimesView();
        var delegate = new GarminBusDelegate(_mainView);
        return [ _mainView, delegate ];
    }

}

function getApp() as GarminBusApp {
    return Application.getApp() as GarminBusApp;
}