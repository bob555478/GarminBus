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

    function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        if (_view.isOnNearbyCard()) {
            openNearbySearch();
            return true;
        }
        var coords = clickEvent.getCoordinates();
        if (coords != null && coords.size() >= 2) {
            var busIdx = _view.getBusIndexAtPoint(coords[0], coords[1]);
            if (busIdx >= 0) {
                var station = _view.getCurrentStation();
                if (station != null) {
                    var buses = station.getBuses();
                    if (busIdx < buses.size()) {
                        openBusRouteMap(station, buses[busIdx]);
                        return true;
                    }
                }
            }
        }
        return false;
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

    public function openBusRouteMap(station as Station, busInfo as Dictionary) as Void {
        var mapView = new BusRouteMapView(station, busInfo);
        var mapDelegate = new BusRouteMapDelegate(mapView);
        WatchUi.pushView(mapView, mapDelegate, WatchUi.SLIDE_LEFT);
    }

    private function openStationActionMenu() as Void {
        var station = _view.getCurrentStation();
        var title = (station != null) ? station.getDisplayName() : "Options";
        var menu = new WatchUi.Menu2({ :title => title });

        if (station != null) {
            // Put Favorite & Nickname actions right at the top so they are immediately accessible
            var isFav = FavoritesStorage.isFavorite(station.getStationCode());
            var favLabel = isFav ? "Remove Favorite" : "Add to Favorites";
            var favSub = "Stop #" + station.getStationCode();
            menu.addItem(new WatchUi.MenuItem(favLabel, favSub, :action_toggle_fav, null));

            var currentNick = station.getNickname();
            var nickSub = (currentNick.length() > 0) ? ("Current: " + currentNick) : "Watch or Phone KB";
            menu.addItem(new WatchUi.MenuItem("Set Nickname", nickSub, :action_nickname, null));

            menu.addItem(new WatchUi.MenuItem("Refresh Arrivals", "Fetch live times", :action_refresh, null));

            // Upcoming bus lines to open live route map
            var buses = station.getBuses();
            var maxBuses = (buses.size() > 4) ? 4 : buses.size();
            for (var i = 0; i < maxBuses; i++) {
                var bus = buses[i];
                var routeNum = Utils.toStringSafe(bus["route"], "?");
                var etaLabel = Utils.toStringSafe(bus["eta_label"], "--");
                var reason = Utils.toStringSafe(bus["status_reason"], "Sched");
                var label = "Line " + routeNum + " (" + etaLabel + ")";
                var subLabel = "Route Map | " + reason;
                menu.addItem(new WatchUi.MenuItem(label, subLabel, i, null));
            }
        }

        menu.addItem(new WatchUi.MenuItem("Station Map", "Select on GPS Map", :action_nearby, null));

        WatchUi.pushView(menu, new StationActionMenuDelegate(_view, self), WatchUi.SLIDE_UP);
    }

    // Prompt user whether to open a keyboard on the watch or on the phone instead
    public function openNicknameMethodMenu(station as Station) as Void {
        var menu = new WatchUi.Menu2({ :title => "Nickname Input" });

        menu.addItem(new WatchUi.MenuItem("Watch Keyboard", "Type on watch screen", :nick_watch_kb, null));
        menu.addItem(new WatchUi.MenuItem("Phone Keyboard", "Type via Garmin App", :nick_phone_kb, null));

        if (WatchUi has :TextPicker) {
            menu.addItem(new WatchUi.MenuItem("System TextPicker", "Native watch input", :nick_native_kb, null));
        }

        menu.addItem(new WatchUi.MenuItem("Quick Presets", "Home, Work, Gym...", :nick_presets, null));

        if (station.getNickname().length() > 0) {
            menu.addItem(new WatchUi.MenuItem("Reset Nickname", "Restore original name", :nick_clear, null));
        }

        WatchUi.pushView(menu, new NicknameMethodMenuDelegate(station, _view), WatchUi.SLIDE_LEFT);
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
        var station = _view.getCurrentStation();

        if (id != null && id instanceof Lang.Number) {
            var busIdx = id as Number;
            if (station != null) {
                var buses = station.getBuses();
                if (busIdx >= 0 && busIdx < buses.size()) {
                    WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
                    _parentDelegate.openBusRouteMap(station, buses[busIdx]);
                    return;
                }
            }
            WatchUi.popView(WatchUi.SLIDE_DOWN);
        } else if (id == :action_refresh) {
            WatchUi.popView(WatchUi.SLIDE_DOWN);
            _view.refreshCurrentStation();
        } else if (id == :action_toggle_fav) {
            var wasFav = (station != null) && FavoritesStorage.isFavorite(station.getStationCode());
            _view.toggleCurrentFavorite();
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            // When newly adding a station to favorites, offer to set a nickname right away
            if (!wasFav && station != null && FavoritesStorage.isFavorite(station.getStationCode())) {
                _parentDelegate.openNicknameMethodMenu(station);
            }
        } else if (id == :action_nickname) {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            if (station != null) {
                _parentDelegate.openNicknameMethodMenu(station);
            }
        } else if (id == :action_nearby) {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            _parentDelegate.openNearbySearch();
        } else {
            WatchUi.popView(WatchUi.SLIDE_DOWN);
        }
    }

    public function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}

class NicknameMethodMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var _station as Station;
    private var _parentView as BusTimesView;

    public function initialize(station as Station, parentView as BusTimesView) {
        Menu2InputDelegate.initialize();
        _station = station;
        _parentView = parentView;
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);

        if (id == :nick_watch_kb) {
            var kbView = new WatchKeyboardView(_station, _parentView);
            var kbDelegate = new WatchKeyboardDelegate(kbView);
            WatchUi.pushView(kbView, kbDelegate, WatchUi.SLIDE_LEFT);
        } else if (id == :nick_phone_kb) {
            // Ensure station is saved in favorites first so phone sync applies to it
            if (!FavoritesStorage.isFavorite(_station.getStationCode())) {
                FavoritesStorage.addFavorite(_station);
            }
            var phoneView = new PhoneKeyboardPromptView(_station, _parentView);
            var phoneDelegate = new PhoneKeyboardPromptDelegate(phoneView);
            WatchUi.pushView(phoneView, phoneDelegate, WatchUi.SLIDE_LEFT);
        } else if (id == :nick_native_kb) {
            if (WatchUi has :TextPicker) {
                var initial = _station.getNickname();
                if (initial.length() == 0) {
                    initial = "Home";
                }
                WatchUi.pushView(
                    new WatchUi.TextPicker(initial),
                    new NativeWatchTextPickerDelegate(_station, _parentView),
                    WatchUi.SLIDE_LEFT
                );
            }
        } else if (id == :nick_presets) {
            openPresetsMenu();
        } else if (id == :nick_clear) {
            FavoritesStorage.setNickname(_station, "");
            _parentView.applyNicknameToStation(_station.getStationCode(), "");
        }
    }

    private function openPresetsMenu() as Void {
        var menu = new WatchUi.Menu2({ :title => "Choose Preset" });
        var presets = ["Home", "Work", "Train Stn", "Central", "Gym", "University", "Mall", "Parents"];
        for (var i = 0; i < presets.size(); i++) {
            menu.addItem(new WatchUi.MenuItem(presets[i], "Stop #" + _station.getStationCode(), presets[i], null));
        }
        WatchUi.pushView(menu, new NicknamePresetMenuDelegate(_station, _parentView), WatchUi.SLIDE_LEFT);
    }

    public function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}

class NicknamePresetMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var _station as Station;
    private var _parentView as BusTimesView;

    public function initialize(station as Station, parentView as BusTimesView) {
        Menu2InputDelegate.initialize();
        _station = station;
        _parentView = parentView;
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var chosen = item.getLabel();
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        FavoritesStorage.setNickname(_station, chosen);
        _parentView.applyNicknameToStation(_station.getStationCode(), chosen);
    }

    public function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}
