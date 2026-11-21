import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.WatchUi;

// Manages Web Mercator projection and a 2x2 grid of road map tiles
// fetched via Communications.makeImageRequest so roads render on all Garmin watches.
class MapTileManager {

    private var _tileSize as Number = 144;
    private var _tileZoom as Number = -1;
    private var _gridStartX as Number = -1;
    private var _gridStartY as Number = -1;

    // 4 tiles in priority order (center tile first)
    private var _tileX as Array<Number> = [0, 0, 0, 0];
    private var _tileY as Array<Number> = [0, 0, 0, 0];
    private var _tileBitmaps as Array<Graphics.BitmapType?> = [null, null, null, null];

    private var _requestGen as Number = 0;
    private var _inFlight as Boolean = false;
    private var _inFlightGen as Number = -1;
    private var _inFlightSlot as Number = -1;
    private var _nextSlot as Number = 0;
    private var _isLoading as Boolean = false;

    public function initialize() {
    }

    // --- Static Web Mercator Projection Helpers ---

    public static function lonToTileX(lon as Float or Double, zoom as Number) as Double {
        var n = Math.pow(2.0, zoom.toDouble());
        return ((lon.toDouble() + 180.0) / 360.0) * n;
    }

    public static function latToTileY(lat as Float or Double, zoom as Number) as Double {
        var clampedLat = lat.toDouble();
        if (clampedLat > 85.0) {
            clampedLat = 85.0;
        } else if (clampedLat < -85.0) {
            clampedLat = -85.0;
        }
        var latRad = clampedLat * Math.PI / 180.0;
        var n = Math.pow(2.0, zoom.toDouble());
        var secPlusTan = Math.tan(latRad) + (1.0 / Math.cos(latRad));
        if (secPlusTan <= 0.0) {
            secPlusTan = 0.000001;
        }
        return ((1.0 - (Math.ln(secPlusTan) / Math.PI)) / 2.0) * n;
    }

    public static function projectToScreen(
        lat as Float or Double,
        lon as Float or Double,
        centerXFloat as Double,
        centerYFloat as Double,
        zoom as Number,
        mapCx as Number,
        mapCy as Number,
        tileSize as Number
    ) as Array<Number> {
        var ptX = lonToTileX(lon, zoom);
        var ptY = latToTileY(lat, zoom);
        var sx = mapCx + ((ptX - centerXFloat) * tileSize.toDouble()).toNumber();
        var sy = mapCy + ((ptY - centerYFloat) * tileSize.toDouble()).toNumber();
        return [sx, sy];
    }

    public static function getScaleMeters(
        lat as Float or Double,
        zoom as Number,
        pixelLength as Number,
        tileSize as Number
    ) as Number {
        var cosLat = Math.cos(lat.toDouble() * Math.PI / 180.0);
        var metersPerTile = (40075016.686 * cosLat) / Math.pow(2.0, zoom.toDouble());
        var metersPerPx = metersPerTile / tileSize.toDouble();
        return (metersPerPx * pixelLength.toDouble()).toNumber();
    }

    // Choose the highest zoom level in [minZoom, maxZoom] where two points fit inside targetSpanPx
    public static function computeOptimalZoom(
        lat1 as Float,
        lon1 as Float,
        lat2 as Float,
        lon2 as Float,
        targetSpanPx as Number,
        tileSize as Number,
        minZoom as Number,
        maxZoom as Number
    ) as Number {
        for (var z = maxZoom; z >= minZoom; z--) {
            var x1 = lonToTileX(lon1, z);
            var y1 = latToTileY(lat1, z);
            var x2 = lonToTileX(lon2, z);
            var y2 = latToTileY(lat2, z);
            var dx = (x2 - x1) * tileSize.toDouble();
            var dy = (y2 - y1) * tileSize.toDouble();
            if (dx < 0.0) {
                dx = -dx;
            }
            if (dy < 0.0) {
                dy = -dy;
            }
            if (dx <= targetSpanPx.toDouble() && dy <= targetSpanPx.toDouble()) {
                return z;
            }
        }
        return minZoom;
    }

    // --- Tile Grid Management ---

    public function getTileSize() as Number {
        return _tileSize;
    }

    public function isLoading() as Boolean {
        return _isLoading;
    }

    public function hasAnyTile() as Boolean {
        for (var i = 0; i < 4; i++) {
            if (_tileBitmaps[i] != null) {
                return true;
            }
        }
        return false;
    }

    public function clear() as Void {
        _requestGen++;
        _isLoading = false;
        _nextSlot = 4;
        _tileZoom = -1;
        _gridStartX = -1;
        _gridStartY = -1;
        _tileBitmaps = [null, null, null, null];
    }

    public function updateForCenter(
        centerLat as Float,
        centerLon as Float,
        zoom as Number,
        tileSize as Number
    ) as Void {
        var clampedSize = tileSize;
        if (clampedSize < 128) {
            clampedSize = 128;
        } else if (clampedSize > 160) {
            clampedSize = 160;
        }

        var centerXFloat = lonToTileX(centerLon, zoom);
        var centerYFloat = latToTileY(centerLat, zoom);
        var baseX = Math.floor(centerXFloat).toNumber();
        var baseY = Math.floor(centerYFloat).toNumber();
        var fx = centerXFloat - baseX.toDouble();
        var fy = centerYFloat - baseY.toDouble();

        // Hysteresis: if we already have a 2x2 grid at this zoom & tileSize and the new center
        // is still comfortably inside it (0.30..1.70 tiles from grid origin), keep the current grid
        // with zero network requests and zero redraw flicker.
        if (_tileZoom == zoom && _tileSize == clampedSize && _gridStartX >= 0 && _gridStartY >= 0) {
            var relX = centerXFloat - _gridStartX.toDouble();
            var relY = centerYFloat - _gridStartY.toDouble();
            if (relX >= 0.30 && relX <= 1.70 && relY >= 0.30 && relY <= 1.70) {
                return;
            }
        }

        var startX = (fx < 0.5) ? (baseX - 1) : baseX;
        var startY = (fy < 0.5) ? (baseY - 1) : baseY;
        var otherX = (fx < 0.5) ? (baseX - 1) : (baseX + 1);
        var otherY = (fy < 0.5) ? (baseY - 1) : (baseY + 1);

        if (_tileZoom == zoom && _gridStartX == startX && _gridStartY == startY && _tileSize == clampedSize) {
            return;
        }

        var newTileX = [baseX, otherX, baseX, otherX] as Array<Number>;
        var newTileY = [baseY, baseY, otherY, otherY] as Array<Number>;
        var newBitmaps = [null, null, null, null] as Array<Graphics.BitmapType?>;

        // Reuse any already-loaded tiles at the same zoom & tileSize instead of re-downloading them
        var anyMissing = false;
        var sameScale = (_tileZoom == zoom && _tileSize == clampedSize);
        for (var i = 0; i < 4; i++) {
            if (sameScale) {
                for (var j = 0; j < 4; j++) {
                    if (_tileBitmaps[j] != null && _tileX[j] == newTileX[i] && _tileY[j] == newTileY[i]) {
                        newBitmaps[i] = _tileBitmaps[j];
                        break;
                    }
                }
            }
            if (newBitmaps[i] == null) {
                anyMissing = true;
            }
        }

        _requestGen++;
        _tileSize = clampedSize;
        _tileZoom = zoom;
        _gridStartX = startX;
        _gridStartY = startY;
        _tileX = newTileX;
        _tileY = newTileY;
        _tileBitmaps = newBitmaps;

        if (!anyMissing) {
            _isLoading = false;
            _nextSlot = 4;
            return;
        }

        _isLoading = true;
        _nextSlot = 0;

        // Never overlap two makeImageRequest calls; if one is in flight,
        // onTileResponse will immediately start fetching missing slots for the new _requestGen.
        if (!_inFlight) {
            fetchNextSlot();
        }
    }

    private function fetchNextSlot() as Void {
        if (_inFlight || _tileZoom < 0) {
            return;
        }

        var maxCoord = Math.pow(2.0, _tileZoom.toDouble()).toNumber();
        while (_nextSlot < 4) {
            // Skip slots that were reused from the previous grid
            if (_tileBitmaps[_nextSlot] != null) {
                _nextSlot++;
                continue;
            }
            var tx = _tileX[_nextSlot];
            var ty = _tileY[_nextSlot];
            if (tx >= 0 && ty >= 0 && tx < maxCoord && ty < maxCoord) {
                // Esri World Street Map requires no API key and uses /{z}/{y}/{x} tile order
                var url = "https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/" +
                    _tileZoom.toString() + "/" + ty.toString() + "/" + tx.toString();

                var options = {
                    :maxWidth => _tileSize,
                    :maxHeight => _tileSize,
                    :dithering => Communications.IMAGE_DITHERING_NONE
                };

                _inFlight = true;
                _inFlightGen = _requestGen;
                _inFlightSlot = _nextSlot;
                _nextSlot++;

                Communications.makeImageRequest(url, null, options, method(:onTileResponse));
                return;
            }
            _nextSlot++;
        }

        _isLoading = false;
        WatchUi.requestUpdate();
    }

    public function onTileResponse(
        responseCode as Number,
        data as Graphics.BitmapReference or WatchUi.BitmapResource or Null
    ) as Void {
        _inFlight = false;

        // If zoom/center changed while this request was in flight, discard old tile
        // and immediately begin fetching the new grid from _nextSlot (0).
        if (_inFlightGen != _requestGen) {
            if (_isLoading && _nextSlot < 4) {
                fetchNextSlot();
            }
            return;
        }

        if (responseCode == 200 && data != null && _inFlightSlot >= 0 && _inFlightSlot < 4) {
            _tileBitmaps[_inFlightSlot] = data;
            WatchUi.requestUpdate();
        } else {
            System.println("Tile fetch failed slot=" + _inFlightSlot + " code=" + responseCode);
        }

        if (_nextSlot < 4) {
            fetchNextSlot();
        } else {
            _isLoading = false;
            WatchUi.requestUpdate();
        }
    }

    // Draw all loaded road map tiles aligned to (centerLat, centerLon) at (mapCx, mapCy).
    // Returns true if at least one tile bitmap was drawn.
    public function drawTiles(
        dc as Dc,
        centerLat as Float,
        centerLon as Float,
        zoom as Number,
        mapCx as Number,
        mapCy as Number
    ) as Boolean {
        if (_tileZoom != zoom) {
            return false;
        }

        var centerXFloat = lonToTileX(centerLon, zoom);
        var centerYFloat = latToTileY(centerLat, zoom);
        var drewAny = false;

        for (var i = 0; i < 4; i++) {
            var bmp = _tileBitmaps[i];
            if (bmp != null) {
                var drawX = mapCx + ((_tileX[i].toDouble() - centerXFloat) * _tileSize.toDouble()).toNumber();
                var drawY = mapCy + ((_tileY[i].toDouble() - centerYFloat) * _tileSize.toDouble()).toNumber();
                dc.drawBitmap(drawX, drawY, bmp);
                drewAny = true;
            }
        }

        return drewAny;
    }

    // Shared helper to draw + and - zoom buttons on the right side of the map
    public static function drawZoomButtons(
        dc as Dc,
        w as Number,
        h as Number,
        zoom as Number,
        minZoom as Number,
        maxZoom as Number,
        highlightActive as Boolean
    ) as Void {
        var btnX = w - 22;
        var plusY = (h * 0.34).toNumber();
        var minusY = (h * 0.52).toNumber();
        var r = 13;

        drawSingleZoomButton(dc, btnX, plusY, r, true, zoom < maxZoom, highlightActive);
        drawSingleZoomButton(dc, btnX, minusY, r, false, zoom > minZoom, highlightActive);
    }

    private static function drawSingleZoomButton(
        dc as Dc,
        cx as Number,
        cy as Number,
        r as Number,
        isPlus as Boolean,
        enabled as Boolean,
        highlightActive as Boolean
    ) as Void {
        dc.setColor(0x0E1E2B, 0x0E1E2B);
        dc.fillCircle(cx, cy, r);

        var borderColor = highlightActive ? 0x00FF66 : 0x00AAFF;
        if (!enabled) {
            borderColor = 0x445566;
        }
        dc.setColor(borderColor, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawCircle(cx, cy, r);

        var glyphColor = enabled ? Graphics.COLOR_WHITE : 0x667788;
        dc.setColor(glyphColor, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawLine(cx - 5, cy, cx + 5, cy);
        if (isPlus) {
            dc.drawLine(cx, cy - 5, cx, cy + 5);
        }
        dc.setPenWidth(1);
    }

    // Returns 1 if '+' was tapped, -1 if '-' was tapped, 0 otherwise
    public static function hitTestZoomButtons(clickX as Number, clickY as Number, w as Number, h as Number) as Number {
        var btnX = w - 22;
        var plusY = (h * 0.34).toNumber();
        var minusY = (h * 0.52).toNumber();
        var hitRadSq = 484; // 22px radius squared for easy tapping

        var dxP = clickX - btnX;
        var dyP = clickY - plusY;
        if ((dxP * dxP) + (dyP * dyP) <= hitRadSq) {
            return 1;
        }

        var dxM = clickX - btnX;
        var dyM = clickY - minusY;
        if ((dxM * dxM) + (dyM * dyM) <= hitRadSq) {
            return -1;
        }

        return 0;
    }

    // Shared helper to draw a compact scale bar on the left side above the bottom HUD
    public static function drawScaleBar(
        dc as Dc,
        x as Number,
        y as Number,
        lat as Float,
        zoom as Number,
        tileSize as Number
    ) as Void {
        var barPx = 36;
        var meters = getScaleMeters(lat, zoom, barPx, tileSize);
        var label = "";
        if (meters >= 1000) {
            var kmTenths = ((meters + 50) / 100).toNumber();
            var kmWhole = kmTenths / 10;
            var kmFrac = kmTenths % 10;
            label = kmWhole.toString() + "." + kmFrac.toString() + "km";
        } else {
            var rounded = ((meters + 5) / 10).toNumber() * 10;
            if (rounded < 10) {
                rounded = 10;
            }
            label = rounded.toString() + "m";
        }

        // Dark pill background for legibility over bright roads
        dc.setColor(0x0E1E2B, 0x0E1E2B);
        dc.fillRoundedRectangle(x - 4, y - 13, barPx + 10, 20, 4);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawLine(x, y + 3, x + barPx, y + 3);
        dc.drawLine(x, y, x, y + 4);
        dc.drawLine(x + barPx, y, x + barPx, y + 4);
        dc.setPenWidth(1);

        dc.drawText(
            x + (barPx / 2),
            y - 13,
            Graphics.FONT_XTINY,
            label,
            Graphics.TEXT_JUSTIFY_CENTER
        );
    }
}
