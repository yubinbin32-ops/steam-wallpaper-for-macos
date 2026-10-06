<div align="center">
  <img src="logo.png" width="96" alt="Steam Wallpaper for macOS Logo" />
  <h1>Steam Wallpaper for macOS</h1>
  <p><strong>High-Performance Native Wallpaper Engine for Apple Silicon & Intel Mac.</strong></p>
  <p>Hardware-accelerated dynamic wallpaper runtime powered by Metal, WebKit, and AVFoundation. Zero Electron.</p>

[![GitHub release](https://img.shields.io/github/v/release/yubinbin32-ops/steam-wallpaper-for-macos)](https://github.com/yubinbin32-ops/steam-wallpaper-for-macos/releases/latest)
[![GitHub stars](https://img.shields.io/github/stars/yubinbin32-ops/steam-wallpaper-for-macos?style=flat)](https://github.com/yubinbin32-ops/steam-wallpaper-for-macos/stargazers)
[![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-brightgreen)](https://apple.com/macos)
[![Swift 5.10+](https://img.shields.io/badge/Swift-5.10%2B-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Metal Acceleration](https://img.shields.io/badge/Render-Metal%20%7C%20WebKit%20%7C%20AVFoundation-blue)](https://developer.apple.com/metal/)
[![MIT license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

<p>Native Metal Pipeline · 1:1 WebKit Bridge · Hardware-Decoded 4K · ~50MB RAM Footprint</p>

[English](README.md) · [简体中文](README_zh.md) · [Download & Install](#download--installation) · [Compatibility](#wallpaper-compatibility-matrix) · [Core Features](#core-features) · [Architecture](#technical-architecture)
</div>

---

## Give your Mac desktop the native Wallpaper Engine it deserves

![Desktop Preview](docs/images/desktop_preview.jpg)

**Steam Wallpaper for macOS** is a lightweight, pure Swift companion application designed specifically to run Steam Wallpaper Engine wallpapers natively on macOS. Engineered directly upon Apple's graphics and multimedia frameworks (SwiftUI + AppKit + Metal + WebKit + AVFoundation), it delivers buttery-smooth 60fps+ desktop wallpapers with negligible battery drain and near-zero CPU usage.

Say goodbye to sluggish web wrappers, bloated Electron runtimes, and overheating laptop fans. By integrating directly into macOS's lowest window level (`.desktopWindow`) with hardware acceleration, your favorite wallpapers run seamlessly in the background without disturbing your daily workflow.

---

## Wallpaper Compatibility Matrix

With the latest architecture upgrade, **Steam Wallpaper for macOS** natively supports all four primary Wallpaper Engine formats:

| Wallpaper Format | Support Status | Rendering Pipeline | Technical Highlights |
| :--- | :---: | :--- | :--- |
| **Scene (`.pkg` / 2D)** | **Perfect Support** | Native Metal (`MetalScenePipeline`) + SpriteKit | Native PKG unpacking, pure Swift LZ4 block decompressor, TEX texture decoding, multi-layer 2D sprite composition, dynamic particle simulation (rain, stars, smoke, glow), and synchronized audio playback. |
| **Web (`HTML5` / `WebGL`)** | **Perfect Support** | Native WebKit (`WKWebView`) + `WebWallpaperBridge` | 1:1 Wallpaper Engine JavaScript API bridge (`window.wallpaperPropertyListener`), Canvas & WebGL 3D rendering, CSS3 animations, local sandbox access, and automatic audio mute/lifecycle control. |
| **Video (`MP4` / `WebM`)** | **Perfect Support** | Native `AVFoundation` + Hardware VideoToolbox | 4K 60fps ultra-smooth playback, zero-stutter seamless looping (`AVPlayerLooper`), hardware decoding, <0.5% CPU overhead, and completely cool operation. |
| **Image (`Static`)** | **Perfect Support** | Native `AppKit` / `CoreGraphics` | Ultra-high-resolution texture extraction, intelligent Aspect Fill center cropping, zero aspect ratio distortion across Retina MacBook screens and ultrawide monitors. |

---

## Prerequisites

To download wallpapers directly via Steam's official high-speed CDN without credentials or third-party proxies, please ensure:

1. **Wallpaper Engine purchased on your Steam account**:
   - The official Steam Workshop download API requires account ownership of Wallpaper Engine to authorize downloads.
2. **Keep the Steam client running during downloads**:
   - The app communicates with your local running Steam client via native IPC to trigger downloads directly from Steam's official servers. **Keep Steam running and logged in while downloading wallpapers**.
3. **Copy the Workshop link**:
   - Simply copy any Wallpaper Engine Workshop URL or numeric item ID directly from Steam or your browser.

---

## Download & Installation

Every release is automatically compiled, packaged, and verified via GitHub Actions:

1. Go to the [**Releases**](https://github.com/yubinbin32-ops/steam-wallpaper-for-macos/releases) page.
2. Download the latest `SteamWallpaper-macOS.zip` archive.
3. Unzip the file and drag `Wallpaper.app` into your `/Applications` folder.
4. Double-click to launch!

> [!NOTE]
> *If macOS displays a warning stating "cannot be opened because the developer cannot be verified", open **System Settings** -> **Privacy & Security** -> scroll down to the Security section and click **"Open Anyway"**.*

---

## How the Engine Works

```text
Steam Workshop (URL / Item ID)
          │
          ▼
Steam Client IPC (Official High-Speed CDN Channel)
          │
          ▼
WallpaperCore (Parser & Decompressor)
    ├─ Scene (.pkg / scene.json) ──► MetalScenePipeline (Metal 2D + LZ4 + Particles)
    ├─ Web (index.html)          ──► WKWebView + WebWallpaperBridge (1:1 JS APIs)
    ├─ Video (.mp4 / .webm)      ──► AVPlayerLooper (Hardware VideoToolbox)
    └─ Static (TEX / Images)     ──► CoreGraphics (Smart Aspect Fill)
          │
          ▼
Desktop Layer (.desktopWindow) + PowerManager (Full-screen Auto Pause)
```

---

## Core Features

- **One-Click Workshop Direct Download**:
  - Simply paste a Steam Workshop link or item ID. The app delegates the download to the local Steam client via official CDN routes. No third-party proxies, API tokens, or login cookies needed.
- **Extreme Efficiency & Hardware Acceleration**:
  - Zero Electron or third-party Chromium binaries. Built with Apple's native rendering pipeline, maintaining an idle memory footprint of only **50~80MB RAM** and zero thermal throttling.
- **Intelligent Power Guardian (`PowerManager`)**:
  - Automatically senses full-screen applications (e.g., Xcode, VS Code, full-screen video, games). Instantly pauses wallpaper rendering to release 100% GPU/CPU power; seamlessly resumes when exiting full-screen.
- **Smart Aspect Ratio Adaptation**:
  - Strictly preserves original image proportions using Aspect Fill. Tailored for 16:10 MacBook Retina displays, 16:9 monitors, and 21:9 / 32:9 ultrawide screens without stretching or distortion.
- **Resident Menu Bar Controller (`StatusBarController`)**:
  - Quick-access status bar icon provides instant controls: one-click mute, pause/resume, cycle wallpapers, and open the wallpaper gallery.

---

## Quick Start Guide

1. **Keep Steam Running**:
   - Ensure the Steam desktop client is launched and logged in in the background.
2. **Copy a Workshop Link**:
   - Browse the Wallpaper Engine Workshop on Steam, right-click any wallpaper and choose **"Copy Page URL"** (e.g., `https://steamcommunity.com/sharedfiles/filedetails/?id=2945179021`), or copy the item ID.
   
   ![Copy Steam Workshop Link Example](docs/images/workshop_link_demo.png)

3. **Paste & Download**:
   - In **Steam Wallpaper for macOS**, paste the URL into the top search bar and click **"Download & Extract"**.
   - The app will automatically download, unpack, and set it as your live desktop wallpaper!
4. **Manage Your Library**:
   - Downloaded wallpapers are stored in your local gallery.
   - Click **"Apply"** on any wallpaper card to switch instantly.
   - Click the folder icon to reveal the wallpaper files directly in Finder.

---

## Building & Development

### Requirements
- macOS 14.0 (Sonoma) or later
- Xcode 15+ / Swift 5.10+ toolchain

### Local Compilation & Packaging

```bash
# 1. Run quick start script
./run.sh

# 2. Or build release binary using Swift Package Manager
swift build -c release

# 3. Package into Wallpaper.app (add --zip to create a release zip)
./bundle.sh --zip
```


---

## Technical Architecture

```text
Sources/
├── WallpaperCore/                 # Core Foundation & Engine Pipelines
│   ├── Models.swift               # Wallpaper metadata, types, and download models
│   ├── SteamWorkshopService.swift # Workshop URL parsing & metadata fetching
│   ├── SteamDownloader.swift      # Local Steam client IPC bridge & download monitor
│   ├── WallpaperParser.swift      # project.json & scene.pkg binary unpacker
│   ├── MetalScenePipeline.swift   # Metal 2D rendering, LZ4 decompressor & shader pipeline
│   ├── SceneRenderer.swift        # SpriteKit + Metal particle & scene compositor
│   ├── WebWallpaperBridge.swift   # Official Wallpaper Engine JS API bridge & sandbox handler
│   ├── DesktopEngine.swift        # Desktop-level NSWindow, AVPlayer, Metal & WebKit controller
│   ├── PowerManager.swift         # Full-screen app detection & low-power sleep manager
│   └── WallpaperStore.swift       # Reactive state management & local gallery sync
└── WallpaperApp/                  # Native SwiftUI Frontend Application
    ├── AppEntry.swift             # Application entry point & lifecycle management
    ├── StatusBarController.swift  # Resident menu bar tray controller
    └── Views/
        ├── GalleryView.swift      # Wallpaper gallery grid UI
        ├── WallpaperCardView.swift# Interactive wallpaper card component
        └── DownloadBarView.swift  # Workshop URL input & download trigger bar
```

---

## License & Disclaimer

- Distributed under the **MIT License**. See [LICENSE](LICENSE) for more details.
- All wallpapers downloaded from the Steam Workshop remain the copyright of their respective creators.
- Steam and Wallpaper Engine are registered trademarks of Valve Corporation and Wallpaper Engine GmbH. This project is an independent open-source tool and is not affiliated with Valve or Wallpaper Engine.
