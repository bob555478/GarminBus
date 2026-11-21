import Toybox.Application.Storage;
import Toybox.Application.Properties;
import Toybox.Lang;

class FavoritesStorage {

    private static const STORAGE_KEY = "favorite_stations_v3";

    // Returns Array of Dictionaries:
    // [{ "name" => String, "code" => String, "lat" => Float, "lon" => Float, "nickname" => String }, ...]
    public static function loadFavorites() as Array<Dictionary> {
        var stored = Storage.getValue(STORAGE_KEY);
        if (stored != null && stored instanceof Lang.Array) {
            var arr = stored as Array<Dictionary>;
            for (var i = 0; i < arr.size(); i++) {
                var item = arr[i];
                var code = Utils.toStringSafe(item["code"], "");
                var name = Utils.toStringSafe(item["name"], "");
                item["name"] = Utils.ensureAsciiStationName(name, code);

                var nick = Utils.toStringSafe(item["nickname"], "");
                if (nick.length() > 0) {
                    item["nickname"] = Utils.ensureAsciiStationName(nick, code);
                }
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

    public static function getNickname(stationCode as String) as String {
        var favs = loadFavorites();
        for (var i = 0; i < favs.size(); i++) {
            var item = favs[i];
            if (stationCode.equals(item["code"])) {
                return Utils.toStringSafe(item["nickname"], "");
            }
        }
        return "";
    }

    public static function setNickname(station as Station, nickname as String) as Void {
        var code = station.getStationCode();
        var cleanNick = (nickname.length() > 0) ? Utils.ensureAsciiStationName(nickname, code) : "";
        station.setNickname(cleanNick);

        var favs = loadFavorites();
        var found = false;
        for (var i = 0; i < favs.size(); i++) {
            var item = favs[i];
            if (code.equals(item["code"])) {
                item["nickname"] = cleanNick;
                found = true;
                break;
            }
        }

        // If setting a nickname on a station not yet in favorites, automatically add it to favorites
        if (!found) {
            favs.add({
                "name" => Utils.ensureAsciiStationName(station.getStationName(), code),
                "code" => code,
                "lat" => station.getLat(),
                "lon" => station.getLon(),
                "nickname" => cleanNick
            });
        }
        saveFavorites(favs);
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
            "lon" => station.getLon(),
            "nickname" => station.getNickname()
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

    // Sync nicknames typed on the phone in Garmin Connect App Settings ("21454=Home,34052=Work")
    // or a single plain string if one station is being edited
    public static function syncPhoneNicknames(targetStationCode as String?) as Boolean {
        var propVal = null as Object?;
        try {
            propVal = Properties.getValue("phone_nicknames");
        } catch (e) {
            return false;
        }

        if (propVal == null || !(propVal instanceof Lang.String)) {
            return false;
        }

        var raw = propVal as String;
        if (raw.length() == 0) {
            return false;
        }

        var favs = loadFavorites();
        var changed = false;

        // Parse comma-separated pairs "code=Nick" or apply directly to targetStationCode if no '=' is present
        var remaining = raw;
        while (remaining.length() > 0) {
            var commaIdx = remaining.find(",");
            var token = remaining;
            if (commaIdx != null) {
                var sub = remaining.substring(0, commaIdx);
                token = (sub != null) ? sub : "";
                var nextStart = commaIdx + 1;
                if (nextStart < remaining.length()) {
                    var restSub = remaining.substring(nextStart, remaining.length());
                    remaining = (restSub != null) ? restSub : "";
                } else {
                    remaining = "";
                }
            } else {
                remaining = "";
            }

            if (token.length() == 0) {
                continue;
            }

            var eqIdx = token.find("=");
            if (eqIdx != null && eqIdx > 0) {
                var codePart = token.substring(0, eqIdx);
                var nickPart = (eqIdx + 1 < token.length()) ? token.substring(eqIdx + 1, token.length()) : "";
                if (codePart != null && nickPart != null && nickPart.length() > 0) {
                    for (var i = 0; i < favs.size(); i++) {
                        if (codePart.equals(favs[i]["code"])) {
                            favs[i]["nickname"] = Utils.ensureAsciiStationName(nickPart, codePart);
                            changed = true;
                        }
                    }
                }
            } else if (targetStationCode != null && targetStationCode.length() > 0) {
                for (var i = 0; i < favs.size(); i++) {
                    if (targetStationCode.equals(favs[i]["code"])) {
                        favs[i]["nickname"] = Utils.ensureAsciiStationName(token, targetStationCode);
                        changed = true;
                    }
                }
            }
        }

        if (changed) {
            saveFavorites(favs);
        }
        return changed;
    }
}
