import Toybox.Application.Storage;
import Toybox.Lang;

class FavoritesStorage {

    private static const STORAGE_KEY = "favorite_stations_v3";

    // Returns Array of Dictionaries:
    // [{ "name" => String, "code" => String, "lat" => Float, "lon" => Float }, ...]
    public static function loadFavorites() as Array<Dictionary> {
        var stored = Storage.getValue(STORAGE_KEY);
        if (stored != null && stored instanceof Lang.Array) {
            var arr = stored as Array<Dictionary>;
            for (var i = 0; i < arr.size(); i++) {
                var item = arr[i];
                var code = Utils.toStringSafe(item["code"], "");
                var name = Utils.toStringSafe(item["name"], "");
                item["name"] = Utils.ensureAsciiStationName(name, code);
            }
            return arr;
        }

        return [] as Array<Dictionary>;
    }

    public static function saveFavorites(favorites as Array<Dictionary>) as Void {
        Storage.setValue(STORAGE_KEY, favorites);
    }

    public static function isFavorite(stationCode as String) as Boolean {
        var favs = loadFavorites();
        for (var i = 0; i < favs.size(); i++) {
            var item = favs[i];
            if (stationCode.equals(item["code"])) {
                return true;
            }
        }
        return false;
    }

    public static function addFavorite(station as Station) as Void {
        var favs = loadFavorites();
        var code = station.getStationCode();
        for (var i = 0; i < favs.size(); i++) {
            if (code.equals(favs[i]["code"])) {
                return;
            }
        }
        favs.add({
            "name" => Utils.ensureAsciiStationName(station.getStationName(), code),
            "code" => code,
            "lat" => station.getLat(),
            "lon" => station.getLon()
        });
        saveFavorites(favs);
    }

    public static function removeFavorite(stationCode as String) as Void {
        var favs = loadFavorites();
        var updated = [] as Array<Dictionary>;
        for (var i = 0; i < favs.size(); i++) {
            var item = favs[i];
            if (!stationCode.equals(item["code"])) {
                updated.add(item);
            }
        }
        saveFavorites(updated);
    }

    public static function toggleFavorite(station as Station) as Boolean {
        var code = station.getStationCode();
        if (isFavorite(code)) {
            removeFavorite(code);
            return false;
        } else {
            addFavorite(station);
            return true;
        }
    }
}
