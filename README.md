# 📺 MPV Stremio Bridge

A high-performance, lightweight bridge that brings the Stremio experience directly into MPV using Golang and the uosc menu interface.

This project bypasses the heavy Stremio Desktop Electron app, offering a hardware-accelerated, minimalist streaming experience with full Real-Debrid support and Trakt.tv synchronization.

## ✨ Features

* **Lightning Fast Search:** Powered by a Go backend with custom weighted scoring for highly relevant results.
* **Intelligent Ranking:** Exact matches and shorter titles are prioritized (e.g., "The Boys" beats "The Boys: Diabolical").
* **Trakt.tv Integration:**
    * **Two-Way Sync:** Resumes exactly where you left off across any Trakt-enabled device.
    * **Smart Scrobbling:** Automatically marks titles as "Watched" at 85% completion.
    * **Sync-on-Quit:** Saves your precise playback timestamp to Trakt the moment you close MPV.
    * **Personalized Menus:** Access your Watchlist, Collection, History, and Trending titles directly.
* **Real-Debrid Integration:** Stream high-quality cached torrents directly via Torrentio.
* **uosc Interface:** Clean, modern menus and search bars integrated into the MPV UI.
* **Asynchronous Loading:** Search results and episode lists load in the background without freezing the player.

## 🛠️ How it Works

The project consists of two main components:
* **The Bridge (main.go):** A compiled CLI tool that communicates with Cinemeta, Torrentio, and Trakt APIs. It handles data processing, OAuth2 authentication, and stream fetching.
* **The UI (mpvstremio.lua):** A Lua script for MPV that handles user input and renders menus using the uosc framework. It uses a synchronous shutdown hook to ensure playback progress is synced to Trakt before the player exits.

## 🚀 Installation

### 1. Prerequisites
* **MPV** installed.
* **uosc** UI plugin installed in MPV.
* **Go** (to compile the bridge).

### 2. Setup the Bridge
Clone the repo and build the executable:

go build -o stremio-bridge main.go

Place the stremio-bridge executable in your main MPV config folder (usually ~/.config/mpv/).

### 3. Configuration
Create a mpvstremio.conf file in the same directory as the bridge:

```ini, TOML
REAL_DEBRID_ENABLED=true
REAL_DEBRID_KEY=YOUR_API_KEY_HERE
TRAKT_CLIENT_ID=YOUR_CLIENT_ID
TRAKT_CLIENT_SECRET=YOUR_CLIENT_SECRET
TRAKT_ACCESS_TOKEN=YOUR_OAUTH_TOKEN
TRAKT_REFRESH_TOKEN=YOUR_REFRESH_TOKEN
```

### 4. Install the Script
Copy mpvstremio.lua to your MPV scripts folder.

## ⌨️ Controls

This script uses standard MPV script-bindings. To use it, add the following line to your input.conf file:

b script-binding stremio-menu

* **b**: Open the Stremio Search Menu (or whichever key you assigned).
* **Select the Category**: Choose between Movies, Shows, or Trakt-specific lists (Watchlist/History).
* **Type and Enter**: Submit your search query.
* **Enter**: Select a Movie/Series or Episode to play.

## ⚖️ License

This project is licensed under the Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0).

**You are free to:**
* **Share** — copy and redistribute the material in any medium or format.
* **Adapt** — remix, transform, and build upon the material.

**Under the following terms:**
* **Attribution** — You must give appropriate credit, provide a link to the license, and indicate if changes were made. You may do so in any reasonable manner, but not in any way that suggests the licensor endorses you or your use.
* **Non-Commercial** — You may not use the material for commercial purposes.
* **No additional restrictions** — You may not apply legal terms or technological measures that legally restrict others from doing anything the license permits.
