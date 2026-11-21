import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

class AddStationByIdView extends WatchUi.View {

    private var _parentView as BusTimesView;
    private var _digits as Array<Number> = [2, 0, 0, 0, 0];
    private var _cursor as Number = 0; // 0..(_digits.size()-1) are digits; _digits.size() is the ADD button
    private var _isLookingUp as Boolean = false;
    private var _errorMsg as String? = null;
    private var _screenW as Number = 260;
    private var _screenH as Number = 260;

    public function initialize(parentView as BusTimesView) {
        View.initialize();
        _parentView = parentView;
    }

    public function onLayout(dc as Dc) as Void {
        _screenW = dc.getWidth();
        _screenH = dc.getHeight();
    }

    public function isLookingUp() as Boolean {
        return _isLookingUp;
    }

    public function changeDigit(delta as Number) as Void {
        if (_isLookingUp) {
            return;
        }
        _errorMsg = null;
        if (_cursor >= 0 && _cursor < _digits.size()) {
            var val = (_digits[_cursor] + delta) % 10;
            if (val < 0) {
                val += 10;
            }
            _digits[_cursor] = val;
            WatchUi.requestUpdate();
        }
    }

    public function advanceOrSubmit() as Void {
        if (_isLookingUp) {
            return;
        }
        _errorMsg = null;
        if (_cursor < _digits.size()) {
            _cursor++;
            WatchUi.requestUpdate();
        } else {
            submitStationId();
        }
    }

    // Returns true if handled internally (moved cursor back), false if view should pop
    public function stepBack() as Boolean {
        if (_isLookingUp) {
            _isLookingUp = false;
            WatchUi.requestUpdate();
            return true;
        }
        if (_cursor > 0) {
            _cursor--;
            _errorMsg = null;
            WatchUi.requestUpdate();
            return true;
        }
        return false;
    }

    // Toggle between 5-digit (standard Israeli stop ID) and 6-digit mode via MENU button
    public function toggleDigitLength() as Void {
        if (_isLookingUp) {
            return;
        }
        _errorMsg = null;
        if (_digits.size() == 5) {
            _digits.add(0);
        } else {
            _digits = [_digits[0], _digits[1], _digits[2], _digits[3], _digits[4]];
            if (_cursor > _digits.size()) {
                _cursor = _digits.size();
            }
        }
        WatchUi.requestUpdate();
    }

    public function handleTap(clickX as Number, clickY as Number) as Boolean {
        if (_isLookingUp) {
            return true;
        }

        var w = _screenW;
        var h = _screenH;
        var count = _digits.size();

        // Check bottom ADD button
        var btnY = (h * 0.69).toNumber();
        var btnH = (h * 0.16).toNumber();
        if (clickY >= btnY - 6 && clickY <= btnY + btnH + 6) {
            submitStationId();
            return true;
        }

        // Check digit columns
        var boxW = (count == 6) ? (w * 0.125).toNumber() : (w * 0.145).toNumber();
        var gap = (count == 6) ? 3 : 5;
        var totalW = (count * boxW) + ((count - 1) * gap);
        var startX = (w - totalW) / 2;
        var boxY = (h * 0.38).toNumber();
        var boxH = (h * 0.20).toNumber();

        for (var i = 0; i < count; i++) {
            var bx = startX + (i * (boxW + gap));
            if (clickX >= bx - 2 && clickX <= bx + boxW + 2) {
                if (clickY >= boxY - 26 && clickY < boxY) {
                    _cursor = i;
                    changeDigit(1);
                    return true;
                } else if (clickY > boxY + boxH && clickY <= boxY + boxH + 26) {
                    _cursor = i;
                    changeDigit(-1);
                    return true;
                } else if (clickY >= boxY && clickY <= boxY + boxH) {
                    if (_cursor == i) {
                        changeDigit(1);
                    } else {
                        _cursor = i;
                        _errorMsg = null;
                        WatchUi.requestUpdate();
                    }
                    return true;
                }
            }
        }

        return false;
    }

    private function buildCodeString() as String {
        var raw = "";
        for (var i = 0; i < _digits.size(); i++) {
            raw += _digits[i].toString();
        }
        // Strip leading zeros so 4-digit codes like 05001 work as 5001
        var firstNonZero = 0;
        while (firstNonZero < raw.length() - 1) {
            var ch = raw.substring(firstNonZero, firstNonZero + 1);
            if (!"0".equals(ch)) {
                break;
            }
            firstNonZero++;
        }
        var trimmed = raw.substring(firstNonZero, raw.length());
        return (trimmed != null) ? trimmed : raw;
    }

    public function submitStationId() as Void {
        var code = buildCodeString();
        if (code.length() == 0 || "0".equals(code)) {
            _errorMsg = "Enter a valid stop ID";
            WatchUi.requestUpdate();
            return;
        }

        _isLookingUp = true;
        _errorMsg = null;
        WatchUi.requestUpdate();

        api_requester.get_station_arrivals(
            code,
            method(:onLookupSuccess),
            method(:onLookupError)
        );
    }

    public function onLookupSuccess(data as Object) as Void {
        if (!_isLookingUp) {
            return;
        }
        _isLookingUp = false;

        var code = buildCodeString();
        if (data == null || !(data instanceof Lang.Dictionary)) {
            _errorMsg = "Stop #" + code + " not found";
            WatchUi.requestUpdate();
            return;
        }

        var resp = data as Dictionary;
        var errorsObj = resp["errors"];
        if (errorsObj != null && errorsObj instanceof Lang.Array) {
            var errArr = errorsObj as Array;
            if (errArr.size() > 0) {
                _errorMsg = "Invalid stop #" + code;
                WatchUi.requestUpdate();
                return;
            }
        }

        var stopInfoObj = resp["stop_info"];
        if (stopInfoObj == null || !(stopInfoObj instanceof Lang.Dictionary)) {
            _errorMsg = "Stop #" + code + " not found";
            WatchUi.requestUpdate();
            return;
        }

        var st = new Station("Station " + code, code, [], api_requester);
        // Reuse the fetched response to populate station name, coordinates, and live arrivals immediately
        st.on_arrivals_received(data);

        // Save to favorites so it persists across app launches
        FavoritesStorage.addFavorite(st);
        _parentView.openPreviewStation(st);
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }

    public function onLookupError(statusCode as Number, errorMsg as String) as Void {
        if (!_isLookingUp) {
            return;
        }
        _isLookingUp = false;
        if (statusCode == -104) {
            _errorMsg = "No Phone BLE (-104)";
        } else {
            _errorMsg = "Lookup failed (" + statusCode + ")";
        }
        WatchUi.requestUpdate();
    }

    public function onUpdate(dc as Dc) as Void {
        _screenW = dc.getWidth();
        _screenH = dc.getHeight();
        var w = _screenW;
        var h = _screenH;

        dc.setColor(0x061018, 0x061018);
        dc.clear();

        // Title
        dc.setColor(0x00AAFF, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            (h * 0.08).toNumber(),
            Graphics.FONT_SMALL,
            "Add Stop by ID",
            Graphics.TEXT_JUSTIFY_CENTER
        );

        // Subtitle / Status
        if (_isLookingUp) {
            dc.setColor(0x00FFAA, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                w / 2,
                (h * 0.22).toNumber(),
                Graphics.FONT_XTINY,
                "Looking up #" + buildCodeString() + "...",
                Graphics.TEXT_JUSTIFY_CENTER
            );
        } else if (_errorMsg != null) {
            dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                w / 2,
                (h * 0.22).toNumber(),
                Graphics.FONT_XTINY,
                _errorMsg,
                Graphics.TEXT_JUSTIFY_CENTER
            );
        } else {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                w / 2,
                (h * 0.22).toNumber(),
                Graphics.FONT_XTINY,
                "UP/DN: Digit  SEL: Next",
                Graphics.TEXT_JUSTIFY_CENTER
            );
        }

        // Digit boxes
        var count = _digits.size();
        var boxW = (count == 6) ? (w * 0.125).toNumber() : (w * 0.145).toNumber();
        var gap = (count == 6) ? 3 : 5;
        var totalW = (count * boxW) + ((count - 1) * gap);
        var startX = (w - totalW) / 2;
        var boxY = (h * 0.38).toNumber();
        var boxH = (h * 0.20).toNumber();

        for (var i = 0; i < count; i++) {
            var bx = startX + (i * (boxW + gap));
            var isActive = (!_isLookingUp && _cursor == i);

            dc.setColor(isActive ? 0x16324A : 0x0E1E2B, isActive ? 0x16324A : 0x0E1E2B);
            dc.fillRoundedRectangle(bx, boxY, boxW, boxH, 6);

            dc.setColor(isActive ? 0x00FF66 : 0x335577, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(isActive ? 2 : 1);
            dc.drawRoundedRectangle(bx, boxY, boxW, boxH, 6);
            dc.setPenWidth(1);

            dc.setColor(isActive ? 0x00FF66 : Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                bx + (boxW / 2),
                boxY + (boxH / 2),
                Graphics.FONT_MEDIUM,
                _digits[i].toString(),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );

            // Draw up/down chevron arrows on active digit slot
            if (isActive) {
                var cx = bx + (boxW / 2);
                dc.setColor(0x00FF66, 0x00FF66);
                dc.fillPolygon([
                    [cx, boxY - 12],
                    [cx - 6, boxY - 4],
                    [cx + 6, boxY - 4]
                ]);
                dc.fillPolygon([
                    [cx, boxY + boxH + 12],
                    [cx - 6, boxY + boxH + 4],
                    [cx + 6, boxY + boxH + 4]
                ]);
            }
        }

        // Bottom Confirm / Add button
        var btnFocused = (!_isLookingUp && _cursor == count);
        var btnW = (w * 0.56).toNumber();
        var btnH = (h * 0.14).toNumber();
        var btnX = (w - btnW) / 2;
        var btnY = (h * 0.70).toNumber();

        dc.setColor(btnFocused ? 0x00AA55 : 0x122636, btnFocused ? 0x00AA55 : 0x122636);
        dc.fillRoundedRectangle(btnX, btnY, btnW, btnH, 8);
        dc.setColor(btnFocused ? 0x00FF66 : 0x00AAFF, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(btnFocused ? 2 : 1);
        dc.drawRoundedRectangle(btnX, btnY, btnW, btnH, 8);
        dc.setPenWidth(1);

        var btnLabel = _isLookingUp ? "Searching..." : ("Add #" + buildCodeString());
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            btnY + (btnH / 2),
            Graphics.FONT_XTINY,
            btnLabel,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // Footer hint for 5/6 digit toggle
        dc.setColor(0x557799, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            (h * 0.87).toNumber(),
            Graphics.FONT_XTINY,
            "HOLD UP: " + ((count == 5) ? "6 digits" : "5 digits"),
            Graphics.TEXT_JUSTIFY_CENTER
        );
    }
}

class AddStationByIdDelegate extends WatchUi.BehaviorDelegate {

    private var _view as AddStationByIdView;

    public function initialize(view as AddStationByIdView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    public function onPreviousPage() as Boolean {
        _view.changeDigit(1);
        return true;
    }

    public function onPrevPage() as Boolean {
        _view.changeDigit(1);
        return true;
    }

    public function onNextPage() as Boolean {
        _view.changeDigit(-1);
        return true;
    }

    public function onSelect() as Boolean {
        _view.advanceOrSubmit();
        return true;
    }

    public function onMenu() as Boolean {
        _view.toggleDigitLength();
        return true;
    }

    public function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        var coords = clickEvent.getCoordinates();
        if (coords != null && coords.size() >= 2) {
            if (_view.handleTap(coords[0], coords[1])) {
                return true;
            }
        }
        return false;
    }

    public function onBack() as Boolean {
        if (_view.stepBack()) {
            return true;
        }
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}
