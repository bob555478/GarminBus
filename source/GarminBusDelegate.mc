import Toybox.Lang;
import Toybox.WatchUi;

class GarminBusDelegate extends WatchUi.BehaviorDelegate {

    private var _view as BusTimesView;

    function initialize(view as BusTimesView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onNextPage() as Boolean {
        _view.switchPage(true);
        return true;
    }

    function onPreviousPage() as Boolean {
        _view.switchPage(false);
        return true;
    }

    // Backwards compatibility if a device calls onPrevPage
    function onPrevPage() as Boolean {
        _view.switchPage(false);
        return true;
    }

    function onSelect() as Boolean {
        if (_view.isOnNearbyCard()) {
            openNearbySearch();
            return true;
        }
        openStationActionMenu();
        return true;
    }

    function onMenu() as Boolean {
        openStationActionMenu();
        return true;
    }

    public function openNearbySearch() as Void {
        var nearbyView = new NearbyStationsView(_view);
        var nearbyDelegate = new NearbyStationsDelegate(nearbyView);
        WatchUi.pushView(nearbyView, nearbyDelegate, WatchUi.SLIDE_LEFT);
    }

    private function openStationActionMenu() as Void {
        var station = _view.getCurrentStation();
        var title = (station != null) ? station.getStationName() : "Options";
        var menu = new WatchUi.Menu2({ :title => title });

        if (station != null) {
            menu.addItem(new WatchUi.MenuItem("Refresh Arrivals", "Fetch live times", :action_refresh, null));

            var isFav = FavoritesStorage.isFavorite(station.getStationCode());
            var favLabel = isFav ? "Remove Favorite" : "Add to Favorites";
            var favSub = "Stop #" + station.getStationCode();
            menu.addItem(new WatchUi.MenuItem(favLabel, favSub, :action_toggle_fav, null));
        }

        menu.addItem(new WatchUi.MenuItem("Station Map", "Select on GPS Map", :action_nearby, null));

        WatchUi.pushView(menu, new StationActionMenuDelegate(_view, self), WatchUi.SLIDE_UP);
    }
}

class StationActionMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var _view as BusTimesView;
    private var _parentDelegate as GarminBusDelegate;

    public function initialize(view as BusTimesView, parentDelegate as GarminBusDelegate) {
        Menu2InputDelegate.initialize();
        _view = view;
        _parentDelegate = parentDelegate;
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        WatchUi.popView(WatchUi.SLIDE_DOWN);

        if (id == :action_refresh) {
            _view.refreshCurrentStation();
        } else if (id == :action_toggle_fav) {
            _view.toggleCurrentFavorite();
        } else if (id == :action_nearby) {
            _parentDelegate.openNearbySearch();
        }
    }

    public function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}
