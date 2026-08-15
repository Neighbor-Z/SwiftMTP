<p align="center">
<img height="128" src="https://github.com/Neighbor-Z/SwiftMTP/blob/main/Materials/MTPIcon-macOS-Default-128x128@2x.png">
</p>



<h1 align="center">SwiftMTP</h1>

<p align="center">
<a href="https://neighbor-z.github.io/swiftmtp-website">Website</a> ·
<a href="https://github.com/Neighbor-Z/SwiftMTP/releases">Releases</a>
</p>

[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg?style=flat)](https://github.com/Neighbor-Z/SwiftMTP/)[![Platform: macOS 12.0+](https://img.shields.io/badge/Platform-macOS%2012.0%2B-blue.svg?style=flat)](https://github.com/Neighbor-Z/SwiftMTP/releases/latest)[![License: GPL](https://img.shields.io/badge/License-GPL-green.svg)](https://github.com/Neighbor-Z/SwiftMTP/blob/main/LICENSE)

**SwiftMTP** is a light-weight, modern, Swift-based utility for interacting with MTP (Media Transfer Protocol) devices on macOS. It allows users to browse, manage, and transfer files between a Mac and external devices like Android phones.

Inspired by [OpenMTP](https://github.com/ganeshrvel/openmtp/), SwiftMTP uses the enhanced backend to provide a consistently high-performance transfer experience while maintaining a compact footprint.

---

## New Feature

Introducing `swiftmtp-cli`. It is a powerful, lightweight macOS command-line interface designed to manage Media Transfer Protocol (MTP) devices with ease. Built natively in Swift and backed by the brand new `Gomtp` backend, it allows users to easily use AI Agent to quickly interact with connected Android devices or cameras.

![CLI](https://github.com/Neighbor-Z/SwiftMTP/blob/main/Materials/CLI.png)

`swiftmtp-cli` is located in `SwiftMTP.app/Contents/MacOS`.

The usage guide `CLI_USAGE.md` is available through the "File" menu - "Export CLI Usage Guide".

---

## Features

- **Device Management**: Easily connect/disconnect MTP devices and select specific storage devices.
- **File Browsing**: Deeply navigate through device directories with a native macOS feel with Quick Look preview supported.
- **Bi-directional Transfer**: Import and export files with support for **Drag-and-Drop**.
- **File Operations**: Create new folders, rename and delete files directly on the device.
- **Progress Tracking**: Real-time transfer progress bars and status indicators.
- **Safe and secure**: No ADB or USB debugging required.
- **Localization**: Multilingual support via `Localizable.xcstrings`.
- **Natural Language Search**: Find your files naturally like a conversation. Just type what you're looking for, e.g., "Photos of last week" or "Work documents from 2024".
- **Device Info Analysis**: Get smart insights about your device hardware, connectivity status, and potential performance optimizations.

For AI details, privacy and security, please read [Details_and_Privacy.md](https://github.com/Neighbor-Z/SwiftMTP/blob/main/Details_and_Privacy.md)

---

## Screenshot

![Main UI](https://github.com/Neighbor-Z/SwiftMTP/blob/main/Materials/screenshot.png)

| File menu with Keyboard Shortcuts                | Go menu with Keyboard Shortcuts              |
| ------------------------------------------------ | -------------------------------------------- |
| ![File Menu](https://github.com/Neighbor-Z/SwiftMTP/blob/main/Materials/file_menu_in_Tahoe.png) | ![Go Menu](https://github.com/Neighbor-Z/SwiftMTP/blob/main/Materials/go_menu_in_Tahoe.png) |

| Natural Language Search                                      | Device Info Analysis                                         |
| ------------------------------------------------------------ | ------------------------------------------------------------ |
| ![NLSearch](https://github.com/Neighbor-Z/SwiftMTP/blob/main/Materials/NLSearch.png) | ![DIA](https://github.com/Neighbor-Z/SwiftMTP/blob/main/Materials/Device_Info_Analysis.png) |


---

## Architecture

The project is structured to bridge high-level Swift with low-level MTP kernel interactions:

```text
SwiftMTP/
├──SwiftMTP/                  # Main App Source
│   ├── SwiftMTPApp.swift     # Entry point
│   ├── Views/                # SwiftUI UI Layer
│   ├── Models/               # Data models
│   └── Services/             # Connection & Transfer logic
├──GomtpShim/                # C shim bridging Swift and the MTP kernel
├──lib/                      # Runtime dependencies (gomtp.dylib, libusb.dylib)
└──swiftmtp-cli/             # cli files
```

---

## Getting Started

### Install

Download [Release](https://github.com/Neighbor-Z/SwiftMTP/releases/latest) or install via homebrew:

```bash
brew tap neighbor-z/swiftmtp && brew install --cask swiftmtp
```

### Build

#### Prerequisites

* **Xcode 15.0+**
* **macOS 12.0+**

#### Build & Run
1.  Open `SwiftMTP.xcodeproj` in Xcode.
3.  Select your target platform (macOS).
4.  Press Run.

---

## Realized

- [x] Drag-and-Drop
- [x] Automatic device connect detection
- [x] Transfer progress bar and status indicators
- [x] Multi selections and export
- [x] "Go" and "File" menu
- [x] Favorites
- [x] Finder-like quick look preview (press spacebar)
- [x] File list font size adjustment 
- [x] Paste to import
- [x] Multiple device connections (v1.1)
- [x] Cancel a transfer (v1.1)

## FAQ

**I got "OpenSession after reset: LIBUSB_ERROR_NOT_FOUND"**

This could be due to other software occupying MTP sessions or a device connection issue. Please ensure software like *Preview*, *Image Capture*, or *Android File Transfer* is not running. For *Android File Transfer*, even if it's not running in the foreground, there is an *Android File Transfer Agent* in the system background to detect USB MTP device connections in real time and automatically launch the main app. You can exit *Android File Transfer Agent* in *Activity Monitor*. After that, please reconnect or restart your device.

**macOS cannot verify this app?**

This is because the app was not released in the way Apple prefers. Apple requires developers to pay $99 annually for a so-called "security signature". Please go to System Settings > Privacy & Security, scroll down and allow the app to run. If the problem still exists, please execute the following command in Terminal and try opening the app once again.

```bash
sudo xattr -rd com.apple.quarantine /Applications/SwiftMTP.app
```

## License

[GPL](https://github.com/Neighbor-Z/SwiftMTP/blob/main/LICENSE)

---
**About AI**: AI assistance involved; each code segment has undergone manual review and testing.

**Need help?** If you encounter any issues, please open an [Issue](https://github.com/Neighbor-Z/SwiftMTP/issues).

**Contributing**: SwiftMTP is always looking for contributions. Just simply fork this repo and make [pull requests](https://github.com/Neighbor-Z/SwiftMTP/pulls). You can also improve the translation or add your new language freely.

**Support project**: [☕️ Buy Me a Coffee](https://buymeacoffee.com/neighbor_z)
