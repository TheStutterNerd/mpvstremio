# 📺 MPV Stremio Bridge

A high-performance, lightweight bridge that brings the Stremio experience directly into MPV using Golang and the uosc menu interface.

This project bypasses the heavy Stremio Desktop Electron app, offering a hardware-accelerated, minimalist streaming experience with full Real-Debrid support.

## ✨ Features

* **Lightning Fast Search:** Powered by a Go backend with custom weighted scoring for highly relevant results.
* **Intelligent Ranking:** Exact matches and shorter titles are prioritized (e.g., "The Boys" beats "The Boys: Diabolical").
* **Real-Debrid Integration:** Stream high-quality cached torrents directly via Torrentio.
* **uosc Interface:** Clean, modern menus and search bars integrated into the MPV UI.
* **Asynchronous Loading:** Search results and episode lists load in the background without freezing the player.

## 🛠️ How it Works

The project consists of two main components:
* **The Bridge (main.go):** A compiled CLI tool that communicates with Cinemeta and Torrentio APIs. It handles the data processing and stream fetching.
* **The UI (mpvstremio.lua):** A Lua script for MPV that handles the user input and renders the menus using the uosc framework.

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

```ini
REAL_DEBRID_ENABLED=true
REAL_DEBRID_KEY=YOUR_API_KEY_HERE
```

### 4. Install the Script
Copy mpvstremio.lua to your MPV scripts folder.

## ⌨️ Controls

This script uses standard MPV script-bindings. To use it, add the following line to your `input.conf` file:

b script-binding stremio-menu

* **b**: Open the Stremio Search Menu (or whichever key you assigned).
* **Select the Category**: Choose between Movies or Shows.
* **Type and Enter**: Submit your search query.
* **Enter**: Select a Movie/Series or Episode to play.

## ⚖️ License

This project is licensed under the Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0).

**You are free to:**
* Share — copy and redistribute the material in any medium or format.
* Adapt — remix, transform, and build upon the material.

**Under the following terms:**
* Attribution — You must give appropriate credit.
* Non-Commercial — You may not use the material for commercial purposes.
