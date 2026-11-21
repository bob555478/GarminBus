import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Lang;

// Custom on-watch keyboard view that works on ALL Garmin watches
// (both 5-button watches like Forerunner 255 Music and touchscreen watches)
class WatchKeyboardView extends WatchUi.View {

    private var _text as String = "";
    private var _station as Station;
    private var _parentView as BusTimesView;

    // 32 keys in a 4x8 grid: A-Z, Space, Del, Clear, Done, plus digits/symbols
    private var _keys as Array<String> = [
        "A", "B", "C", "D", "E", "F", "G", "H",
        "I", "J", "K", "L", "M", "N", "O", "P",
        "Q", "R", "S", "T", "U", "V", "W", "X",
        "Y", "Z", " ", "-", "1", "2", "DEL", "OK"
    ];

    private var _cursorIndex as Number = 0;

    public function initialize(station as Station, parentView as BusTimesView) {
        View.initialize();
        _station = station;
        _parentView = parentView;
        var currentNick = station.getNickname();
        if (currentNick.length() > 0) {
            _text = currentNick;
        }
    }

    public function moveCursor(delta as Number) as Void {
        var total = _keys.size();
        _cursorIndex += delta;
        if (_cursorIndex >= total) {
            _cursorIndex = 0;
        } else if (_cursorIndex < 0) {
            _cursorIndex = total - 1;
        }
        WatchUi.requestUpdate();
    }

    public function pressCurrentKey() as Void {
        var key = _keys[_cursorIndex];
        if ("OK".equals(key)) {
            saveAndClose();
            return;
        } else if ("DEL".equals(key)) {
            if (_text.length() > 0) {
                var sub = _text.substring(0, _text.length() - 1);
                _text = (sub != null) ? sub : "";
            }
        } else {
            if (_text.length() < 16) {
                // Auto-lowercase letters after first character of a word for neatness
                var ch = key;
                if (_text.length() > 0) {
                    var prev = _text.substring(_text.length() - 1, _text.length());
                    if (prev != null && !" ".equals(prev) && !"-".equals(prev)) {
                        ch = key.toLower();
                    }
                }
                _text += ch;
            }
        }
        WatchUi.requestUpdate();
    }

    public function handleTap(clickX as Number, clickY as Number, w as Number, h as Number) as Boolean {
        var gridLeft = (w * 0.12).toNumber();
        var gridTop = (h * 0.34).toNumber();
        var gridW = (w * 0.76).toNumber();
        var gridH = (h * 0.48).toNumber();

        if (clickX >= gridLeft && clickX <= gridLeft + gridW &&
            clickY >= gridTop && clickY <= gridTop + gridH) {
            var col = ((clickX - gridLeft) * 8) / gridW;
            var row = ((clickY - gridTop) * 4) / gridH;
            if (col >= 0 && col < 8 && row >= 0 && row < 4) {
                _cursorIndex = (row * 8) + col;
                pressCurrentKey();
                return true;
            }
        }
        return false;
    }

    public function saveAndClose() as Void {
        FavoritesStorage.setNickname(_station, _text);
        _parentView.applyNicknameToStation(_station.getStationCode(), _text);
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }

    public function onUpdate(dc as Dc) as Void {
        dc.setColor(0x061018, 0x061018);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();

        // Top Title
        dc.setColor(0x00AAFF, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            (h * 0.05).toNumber(),
            Graphics.FONT_XTINY,
            "Watch Keyboard",
            Graphics.TEXT_JUSTIFY_CENTER
        );

        // Text input preview box
        var boxX = (w * 0.16).toNumber();
        var boxY = (h * 0.17).toNumber();
        var boxW = (w * 0.68).toNumber();
        var boxH = (h * 0.13).toNumber();

        dc.setColor(0x122636, 0x122636);
        dc.fillRoundedRectangle(boxX, boxY, boxW, boxH, 6);
        dc.setColor(0x00FF66, Graphics.COLOR_TRANSPARENT);
        dc.drawRoundedRectangle(boxX, boxY, boxW, boxH, 6);

        var displayStr = (_text.length() > 0) ? (_text + "_") : "Type name_";
        dc.setColor((_text.length() > 0) ? Graphics.COLOR_WHITE : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            boxY + (boxH / 2),
            Graphics.FONT_SMALL,
            displayStr,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // 4 rows x 8 cols keyboard grid
        var gridLeft = (w * 0.12).toNumber();
        var gridTop = (h * 0.34).toNumber();
        var gridW = (w * 0.76).toNumber();
        var gridH = (h * 0.47).toNumber();
        var cellW = gridW / 8;
        var cellH = gridH / 4;

        for (var r = 0; r < 4; r++) {
            for (var c = 0; c < 8; c++) {
                var idx = (r * 8) + c;
                var key = _keys[idx];
                var cx = gridLeft + (c * cellW);
                var cy = gridTop + (r * cellH);
                var isSelected = (idx == _cursorIndex);

                if (isSelected) {
                    var highlightColor = "OK".equals(key) ? 0x00AA44 : ("DEL".equals(key) ? 0xAA3333 : 0x0088EE);
                    dc.setColor(highlightColor, highlightColor);
                    dc.fillRoundedRectangle(cx, cy, cellW - 1, cellH - 1, 4);
                } else if ("OK".equals(key)) {
                    dc.setColor(0x0D3B26, 0x0D3B26);
                    dc.fillRoundedRectangle(cx, cy, cellW - 1, cellH - 1, 4);
                } else if ("DEL".equals(key)) {
                    dc.setColor(0x3B1218, 0x3B1218);
                    dc.fillRoundedRectangle(cx, cy, cellW - 1, cellH - 1, 4);
                }

                var label = " ".equals(key) ? "_" : key;
                dc.setColor(isSelected ? Graphics.COLOR_WHITE : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.drawText(
                    cx + (cellW / 2),
                    cy + (cellH / 2),
                    Graphics.FONT_XTINY,
                    label,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
                );
            }
        }

        // Bottom instructions
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            (h * 0.85).toNumber(),
            Graphics.FONT_XTINY,
            "UP/DN:Move  SEL:Key",
            Graphics.TEXT_JUSTIFY_CENTER
        );
    }
}

class WatchKeyboardDelegate extends WatchUi.BehaviorDelegate {

    private var _view as WatchKeyboardView;

    public function initialize(view as WatchKeyboardView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    public function onNextPage() as Boolean {
        _view.moveCursor(1);
        return true;
    }

    public function onPreviousPage() as Boolean {
        _view.moveCursor(-1);
        return true;
    }

    public function onPrevPage() as Boolean {
        _view.moveCursor(-1);
        return true;
    }

    public function onSelect() as Boolean {
        _view.pressCurrentKey();
        return true;
    }

    public function onMenu() as Boolean {
        // Quick shortcut: hold UP/MENU saves immediately
        _view.saveAndClose();
        return true;
    }

    public function onBack() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}

// View explaining how to type the nickname on the paired Phone via Garmin Connect Settings
// and automatically listening for incoming settings changes
class PhoneKeyboardPromptView extends WatchUi.View {

    private var _station as Station;
    private var _parentView as BusTimesView;
    private var _statusText as String = "Waiting for phone...";

    public function initialize(station as Station, parentView as BusTimesView) {
        View.initialize();
        _station = station;
        _parentView = parentView;
    }

    public function checkSyncNow() as Void {
        var code = _station.getStationCode();
        if (FavoritesStorage.syncPhoneNicknames(code)) {
            var newNick = FavoritesStorage.getNickname(code);
            if (newNick.length() > 0) {
                _station.setNickname(newNick);
                _parentView.applyNicknameToStation(code, newNick);
                WatchUi.popView(WatchUi.SLIDE_RIGHT);
                return;
            }
        }
        _statusText = "No update yet. Try again";
        WatchUi.requestUpdate();
    }

    public function onUpdate(dc as Dc) as Void {
        dc.setColor(0x061018, 0x061018);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();
        var code = _station.getStationCode();

        dc.setColor(0x00AAFF, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            (h * 0.08).toNumber(),
            Graphics.FONT_SMALL,
            "Phone Keyboard",
            Graphics.TEXT_JUSTIFY_CENTER
        );

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            (h * 0.25).toNumber(),
            Graphics.FONT_XTINY,
            "Open Garmin Connect",
            Graphics.TEXT_JUSTIFY_CENTER
        );
        dc.drawText(
            w / 2,
            (h * 0.36).toNumber(),
            Graphics.FONT_XTINY,
            "GarminBus -> Settings",
            Graphics.TEXT_JUSTIFY_CENTER
        );

        // Highlight box showing exact format
        dc.setColor(0x122636, 0x122636);
        dc.fillRoundedRectangle((w * 0.14).toNumber(), (h * 0.48).toNumber(), (w * 0.72).toNumber(), (h * 0.17).toNumber(), 6);
        dc.setColor(0x00FF66, Graphics.COLOR_TRANSPARENT);
        dc.drawRoundedRectangle((w * 0.14).toNumber(), (h * 0.48).toNumber(), (w * 0.72).toNumber(), (h * 0.17).toNumber(), 6);

        dc.setColor(0x00FF66, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            (h * 0.56).toNumber(),
            Graphics.FONT_SMALL,
            code + "=MyStop",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            (h * 0.71).toNumber(),
            Graphics.FONT_XTINY,
            _statusText,
            Graphics.TEXT_JUSTIFY_CENTER
        );

        dc.setColor(0xFFCC00, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            (h * 0.83).toNumber(),
            Graphics.FONT_XTINY,
            "SELECT: Sync From Phone",
            Graphics.TEXT_JUSTIFY_CENTER
        );
    }
}

class PhoneKeyboardPromptDelegate extends WatchUi.BehaviorDelegate {

    private var _view as PhoneKeyboardPromptView;

    public function initialize(view as PhoneKeyboardPromptView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    public function onSelect() as Boolean {
        _view.checkSyncNow();
        return true;
    }

    public function onBack() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}

// Native watch TextPicker delegate (for devices with built-in WatchUi.TextPicker support)
class NativeWatchTextPickerDelegate extends WatchUi.TextPickerDelegate {

    private var _station as Station;
    private var _parentView as BusTimesView;

    public function initialize(station as Station, parentView as BusTimesView) {
        TextPickerDelegate.initialize();
        _station = station;
        _parentView = parentView;
    }

    public function onTextEntered(text as String, changed as Boolean) as Boolean {
        if (text.length() > 0) {
            FavoritesStorage.setNickname(_station, text);
            _parentView.applyNicknameToStation(_station.getStationCode(), text);
        }
        return true;
    }

    public function onCancel() as Boolean {
        return true;
    }
}
