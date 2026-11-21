# GarminBus — Project Requirements & Instructions

## Overview
**GarminBus** is a Garmin Connect IQ watch application that allows users to view live and scheduled bus arrival times in Israel directly on their wrist using the **Open Bus Stride API** (`https://open-bus-stride-api.hasadna.org.il`). Users can browse their favorite stations immediately on launch, discover nearby bus stations via GPS, and add/remove favorites easily.

---

## Core Functional Requirements

### 1. App Launch & Navigation Flow
- **Default Screen (Favorites Carousel)**:
  - Opens directly to the user's saved **Favorite Stations** carousel (Up/Down or swipe to switch between favorite stations).
  - Includes a dedicated page or quick action in the carousel/menu to **Scan Nearby Stations** via GPS.
  - If no favorites are saved yet, prompts the user or defaults to scanning nearby stations.
- **Station Actions**:
  - Selecting a station opens its detail/action menu (or toggles favorite status / refreshes live times).
  - From the **Nearby Stations** list, selecting a station shows its live bus times and allows adding it to **Favorites** (persisted via `Toybox.Application.Storage`).

### 2. Display & Language Formatting
- **Station Names**: Keep their original **Hebrew** names as returned by the API (alongside the station code if helpful).
- **Bus Lines**: Display **only the line number** (e.g., `37`, `475`) and the arrival time (minutes until arrival / ETA) — no destination text needed, keeping the UI clean and readable on round screens.

### 3. Inviting UI & Indicative Color Coding
- Designed for quick readability on a round watch face using proportional layout (`dc.getWidth()`, `dc.getHeight()`).
- **Color Coding for Bus Arrival Times & Statuses**:
  - **Green**: Live real-time tracking (active SIRI GPS feed, recent position update, on route).
  - **Gray**: Scheduled time only (GTFS schedule, no live GPS tracking).
  - **Orange**: Stale position update (it has been a moderate amount of time since the bus's last GPS position update).
  - **Red**:
    - Bus is **off-route**; OR
    - Very stale position update (it has been a long time since the bus's last GPS position update).

### 4. Data Source & API Integration
- **Direct API Calls**: Query **Open Bus Stride API** (`https://open-bus-stride-api.hasadna.org.il`) directly from the watch via `Toybox.Communications.makeWebRequest`.
- Keep request limits (`limit`) small and responses compact to stay well within Garmin Connect IQ background/dictionary memory limits.
- **Nearby Stations**: Use the watch's GPS (`Toybox.Position`) coordinates (`lat`, `lon`) to query nearby GTFS/SIRI stops within a bounding box / radius.
- **Live & Scheduled Arrivals**: Fetch SIRI ride stops / vehicle locations and GTFS scheduled times to compute ETA (in minutes), time since last recorded location update (`recorded_at_time`), and route deviation/status.

### 5. Device Compatibility
- **Primary Target Device**: Garmin Forerunner 255 Music (`fr255m` — 260x260 MIP display, 5 physical buttons, no touchscreen).
- **Broad Model Support**: Accessible across most Garmin watches using standard `BehaviorDelegate` actions (`onNextPage`, `onPreviousPage`, `onSelect`, `onBack`, `onMenu`) and resolution-independent drawing.

---

## Technical Note on Existing Code
- The existing code in `GarminBus/` is a rough prototype and not mandatory to preserve. The app structure, views, delegates, and API layer can be refactored or rewritten to cleanly support these requirements.
