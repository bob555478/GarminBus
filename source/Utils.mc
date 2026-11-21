import Toybox.Lang;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.Math;

module Utils {

    // Status constants for bus arrivals
    const STATUS_LIVE_ON_ROUTE = 0;   // Green: Live GPS, fresh update, on route
    const STATUS_SCHEDULED = 1;       // Gray: Scheduled time only (no live feed)
    const STATUS_STALE_WARN = 2;      // Orange: Moderately stale GPS position (2-5 min)
    const STATUS_STALE_OR_OFF = 3;    // Red: Very stale GPS (>5 min) or Off-Route

    // Format current or given Moment as YYYY-MM-DD
    function formatDateISO(moment as Time.Moment) as String {
        var info = Gregorian.utcInfo(moment, Time.FORMAT_SHORT);
        return info.year.format("%04d") + "-" +
               info.month.format("%02d") + "-" +
               info.day.format("%02d");
    }

    // Format Moment as ISO-8601 UTC timestamp: YYYY-MM-DDTHH:MM:SSZ
    function formatTimestampISO(moment as Time.Moment) as String {
        var info = Gregorian.utcInfo(moment, Time.FORMAT_SHORT);
        return info.year.format("%04d") + "-" +
               info.month.format("%02d") + "-" +
               info.day.format("%02d") + "T" +
               info.hour.format("%02d") + ":" +
               info.min.format("%02d") + ":" +
               info.sec.format("%02d") + "Z";
    }

    // Parse an ISO-8601 timestamp string (e.g., "2026-11-21T10:35:00+00:00" or "2026-11-21T12:35:00+02:00" or "...Z")
    // Returns epoch seconds (Number) or null if invalid
    function parseIsoToEpoch(isoStr as String?) as Number? {
        if (isoStr == null || isoStr.length() < 19) {
            return null;
        }

        var yearStr = isoStr.substring(0, 4);
        var monthStr = isoStr.substring(5, 7);
        var dayStr = isoStr.substring(8, 10);
        var hourStr = isoStr.substring(11, 13);
        var minStr = isoStr.substring(14, 16);
        var secStr = isoStr.substring(17, 19);

        if (yearStr == null || monthStr == null || dayStr == null ||
            hourStr == null || minStr == null || secStr == null) {
            return null;
        }

        var year = yearStr.toNumber();
        var month = monthStr.toNumber();
        var day = dayStr.toNumber();
        var hour = hourStr.toNumber();
        var min = minStr.toNumber();
        var sec = secStr.toNumber();

        if (year == null || month == null || day == null ||
            hour == null || min == null || sec == null) {
            return null;
        }

        var moment = Gregorian.moment({
            :year => year,
            :month => month,
            :day => day,
            :hour => hour,
            :minute => min,
            :second => sec
        });

        var epoch = moment.value();

        // Check for timezone offset at the end (e.g. "+02:00" or "-05:00")
        var len = isoStr.length();
        var tzSignIndex = -1;
        var isPlus = true;

        for (var i = 19; i < len; i++) {
            var ch = isoStr.substring(i, i + 1);
            if ("+".equals(ch)) {
                tzSignIndex = i;
                isPlus = true;
                break;
            } else if ("-".equals(ch)) {
                tzSignIndex = i;
                isPlus = false;
                break;
            }
        }

        if (tzSignIndex != -1 && len >= tzSignIndex + 6) {
            var tzHrStr = isoStr.substring(tzSignIndex + 1, tzSignIndex + 3);
            var tzMinStr = isoStr.substring(tzSignIndex + 4, tzSignIndex + 6);
            if (tzHrStr != null && tzMinStr != null) {
                var tzHr = tzHrStr.toNumber();
                var tzMin = tzMinStr.toNumber();
                if (tzHr != null && tzMin != null) {
                    var offsetSec = (tzHr * 3600) + (tzMin * 60);
                    if (isPlus) {
                        epoch -= offsetSec;
                    } else {
                        epoch += offsetSec;
                    }
                }
            }
        }

        return epoch;
    }

    // Approximate distance in meters between two lat/lon coordinates (in degrees)
    function calculateDistanceMeters(lat1 as Float or Double, lon1 as Float or Double, lat2 as Float or Double, lon2 as Float or Double) as Number {
        var rad = Math.PI / 180.0;
        var dLat = (lat2 - lat1) * rad;
        var dLon = (lon2 - lon1) * rad;
        var meanLat = ((lat1 + lat2) / 2.0) * rad;

        var x = dLon * Math.cos(meanLat);
        var y = dLat;
        var distMeters = Math.sqrt((x * x) + (y * y)) * 6371000.0;
        return distMeters.toNumber();
    }

    // Safely convert Object (String, Float, Double, Number) to Float
    function toFloatSafe(val as Object?) as Float? {
        if (val == null) {
            return null;
        }
        if (val instanceof Lang.Float) {
            return val;
        }
        if (val instanceof Lang.Double) {
            return val.toFloat();
        }
        if (val instanceof Lang.Number) {
            return val.toFloat();
        }
        if (val instanceof Lang.String) {
            return val.toFloat();
        }
        return null;
    }

    // Safely convert Object to String
    function toStringSafe(val as Object?, fallback as String) as String {
        if (val == null) {
            return fallback;
        }
        if (val instanceof Lang.String) {
            return val;
        }
        return val.toString();
    }

    // Converts Hebrew station names (which render as <?> diamonds on non-Hebrew Garmin firmware/simulator)
    // into readable English / Latin text by translating common transit terms and transliterating Hebrew letters.
    function ensureAsciiStationName(rawName as String?, stationCode as String) as String {
        if (rawName == null || rawName.length() == 0) {
            return "Station " + stationCode;
        }

        var chars = rawName.toCharArray();
        var hasNonAscii = false;
        for (var i = 0; i < chars.size(); i++) {
            if (chars[i].toNumber() > 127) {
                hasNonAscii = true;
                break;
            }
        }

        if (!hasNonAscii) {
            return rawName;
        }

        // Replace common Hebrew transit words with clean English equivalents before letter-by-letter transliteration
        var text = rawName;
        var dictionary = [
            "מחלף", "Interchange",
            "צומת", "Junction",
            "תחנת רכבת", "Train Stn",
            "רכבת", "Train",
            "ת.רק\"ל", "LRT",
            "רק\"ל", "LRT",
            "תחנה מרכזית", "Central Stn",
            "מרכזית", "Central",
            "בית חולים", "Hospital",
            "בי\"ח", "Hospital",
            "קניון", "Mall",
            "גשר", "Bridge",
            "לה גוורדיה", "LaGuardia",
            "דרך", "Rd",
            "שדרות", "Blvd",
            "שד'", "Blvd",
            "רחוב", "St",
            "רח'", "St",
            "כיכר", "Square",
            "פארק", "Park",
            "מסוף", "Terminal",
            "אוניברסיטת", "Univ",
            "אוניברסיטה", "University",
            "מכללת", "College",
            "תל אביב", "Tel Aviv",
            "ירושלים", "Jerusalem",
            "חיפה", "Haifa",
            "רמת גן", "Ramat Gan",
            "גבעתיים", "Givatayim",
            "בני ברק", "Bnei Brak",
            "חולון", "Holon",
            "בת ים", "Bat Yam",
            "פתח תקווה", "Petah Tikva",
            "ראשון לציון", "Rishon LeZion",
            "הרצליה", "Herzliya",
            "רעננה", "Raanana",
            "כפר סבא", "Kfar Saba",
            "נתניה", "Netanya",
            "אשדוד", "Ashdod",
            "באר שבע", "Beer Sheva",
            "השלום", "HaShalom",
            "ארלוזורוב", "Arlozorov",
            "סבידור", "Savidor",
            "ההגנה", "HaHagana",
            "עזריאלי", "Azrieli",
            "דיזנגוף", "Dizengoff",
            "רוטשילד", "Rothschild",
            "אבן גבירול", "Ibn Gabirol",
            "ז'בוטינסקי", "Jabotinsky",
            "אלנבי", "Allenby",
            "בגין", "Begin",
            "נמיר", "Namir",
            "הירקון", "HaYarkon",
            "בן גוריון", "Ben Gurion",
            "רבין", "Rabin",
            "ויצמן", "Weizmann",
            "הרצל", "Herzl"
        ];

        for (var d = 0; d < dictionary.size(); d += 2) {
            var heb = dictionary[d];
            var eng = dictionary[d + 1];
            var idx = text.find(heb);
            while (idx != null) {
                var before = (idx > 0) ? text.substring(0, idx) : "";
                var afterIdx = idx + heb.length();
                var after = (afterIdx < text.length()) ? text.substring(afterIdx, text.length()) : "";
                if (before != null && after != null) {
                    text = before + eng + after;
                } else {
                    break;
                }
                idx = text.find(heb);
            }
        }

        chars = text.toCharArray();
        var result = "";
        var prevWasSpace = true;

        for (var i = 0; i < chars.size(); i++) {
            var code = chars[i].toNumber();
            var mapped = "";

            if (code >= 32 && code <= 126) {
                mapped = chars[i].toString();
            } else {
                // Hebrew Unicode block: 0x05D0 (1488) to 0x05EA (1514)
                switch (code) {
                    case 1488: // א
                        mapped = "a";
                        break;
                    case 1489: // ב
                        mapped = "b";
                        break;
                    case 1490: // ג
                        mapped = "g";
                        break;
                    case 1491: // ד
                        mapped = "d";
                        break;
                    case 1492: // ה
                        mapped = "h";
                        break;
                    case 1493: // ו
                        mapped = "o";
                        break;
                    case 1494: // ז
                        mapped = "z";
                        break;
                    case 1495: // ח
                        mapped = "ch";
                        break;
                    case 1496: // ט
                        mapped = "t";
                        break;
                    case 1497: // י
                        mapped = "i";
                        break;
                    case 1498: // ך
                    case 1499: // כ
                        mapped = "k";
                        break;
                    case 1500: // ל
                        mapped = "l";
                        break;
                    case 1501: // ם
                    case 1502: // מ
                        mapped = "m";
                        break;
                    case 1503: // ן
                    case 1504: // נ
                        mapped = "n";
                        break;
                    case 1505: // ס
                        mapped = "s";
                        break;
                    case 1506: // ע
                        mapped = "a";
                        break;
                    case 1507: // ף
                    case 1508: // פ
                        mapped = "p";
                        break;
                    case 1509: // ץ
                    case 1510: // צ
                        mapped = "tz";
                        break;
                    case 1511: // ק
                        mapped = "k";
                        break;
                    case 1512: // ר
                        mapped = "r";
                        break;
                    case 1513: // ש
                        mapped = "sh";
                        break;
                    case 1514: // ת
                        mapped = "t";
                        break;
                    default:
                        mapped = "";
                        break;
                }
            }

            if (mapped.length() > 0) {
                if (prevWasSpace && mapped.length() >= 1) {
                    var firstChar = mapped.substring(0, 1);
                    var rest = (mapped.length() > 1) ? mapped.substring(1, mapped.length()) : "";
                    if (firstChar != null && rest != null) {
                        mapped = firstChar.toUpper() + rest;
                    }
                }
                result += mapped;
                prevWasSpace = (" ".equals(mapped) || "/".equals(mapped) || "-".equals(mapped));
            }
        }

        if (result.length() == 0) {
            return "Station " + stationCode;
        }
        return result;
    }

}
