[Back to top](#top)
<a name="top"></a>

<div align="center">
  <img src="WallpaperExtractor/Assets.xcassets/AppIcon.appiconset/512.png" alt="Wallpaper Extractor Logo" width="200"/>
  
  # Wallpaper Extractor
  
[![macOS](https://img.shields.io/badge/macOS-15.1%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-FA7343?logo=swift&logoColor=white)](https://swift.org)
[![Xcode](https://img.shields.io/badge/Xcode-15.0%2B-147EFB?logo=xcode&logoColor=white)](https://developer.apple.com/xcode/)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![GitHub release](https://img.shields.io/github/v/release/trinityhades/WallpaperExtractor?display_name=tag)](#)
[![GitHub last commit](https://img.shields.io/github/last-commit/trinityhades/WallpaperExtractor)](#)

⭐ Star us on GitHub — your support motivates me a lot! 🙏

[![Share](https://img.shields.io/badge/share-000000?logo=x&logoColor=white)](https://x.com/intent/tweet?text=Check%20out%20this%20project%20on%20GitHub:%20https://github.com/trinityhades/WallpaperExtractor%20%23WallpaperEngine%20%23macOS)
[![Share](https://img.shields.io/badge/share-1877F2?logo=facebook&logoColor=white)](https://www.facebook.com/sharer/sharer.php?u=https://github.com/trinityhades/WallpaperExtractor)
[![Share](https://img.shields.io/badge/share-0A66C2?logo=linkedin&logoColor=white)](https://www.linkedin.com/sharing/share-offsite/?url=https://github.com/trinityhades/WallpaperExtractor)

A powerful **macOS** application for downloading and extracting Wallpaper Engine projects directly from the Steam Workshop.

</div>

## 📑 Table of Contents
- [About](#-about)
- [Features](#-features)
- [Installation](#-installation)
  - [Building from Source](#building-from-source)
  - [Installing SteamCMD](#installing-steamcmd)
- [Usage](#-usage)
  - [Steam Workshop Downloads](#steam-workshop-downloads)
  - [Local PKG Files](#local-pkg-files)
- [Supported Formats](#-supported-formats)
- [Technical Details](#-technical-details)
- [Support](#-support)
- [Credits](#-credits)
- [Requirements](#-requirements)
- [License](#-license)
- [Disclaimer](#%EF%B8%8F-disclaimer)

## 🚀 About

**Wallpaper Extractor** is a native macOS application designed to seamlessly download and extract Wallpaper Engine content from Steam Workshop. Built with Swift and SwiftUI, it provides an intuitive interface for browsing package contents, converting textures, and extracting media files with professional-grade quality.

## ✨ Features

- 🔍 **Browse Package Contents**: View the file tree of Wallpaper Engine `.pkg` files with hierarchical indentation
- 🎨 **Texture Conversion**: Automatically converts `.tex` texture files to PNG format
  - Supports RGBA8888, DXT1, DXT3, DXT5, RG88, and R8 formats
  - Handles PNG-embedded textures from TEXB containers
- 🎬 **Video Extraction**: Detects and extracts MP4 videos embedded in `.tex` files
- 📦 **Steam Workshop Integration**: Download wallpapers directly from Steam Workshop
  - Automatic Steam Guard authentication support
  - Real-time download progress tracking
- 💾 **Export…**: Choose destination; selectively export Images, Videos, Other files; optional Flatten; and a "Trinity's Preferred" preset that puts Materials PNGs into `Main Images` and consolidates `effects`, `masks`, `models`, and `xray` into unified top-level folders. Automatically opens the export folder in Finder.
- 🖱️ **Drag Raw Files Out**: Drag any file from the package tree directly to Finder — exports the original bytes without conversion.
- 🖼️ **Live Preview**: Preview images directly in the app

## 📦 Installation

1. Download the latest release
2. Move to Applications folder
3. Install SteamCMD for Workshop downloads (see below)

### Building from Source

1. Clone the repository:
```bash
git clone https://github.com/trinityhades/WallpaperExtractor.git
cd WallpaperExtractor
```

2. Open the project in Xcode:
```bash
open WallpaperExtractor.xcodeproj
```

3. Build and run:
   - Select your target device (Mac)
   - Press `⌘ + R` to build and run
   - Or use `⌘ + B` to build only

**Requirements:**
- Xcode 15.0 or later
- macOS 15.1 SDK or later
- Swift 5.9+

### Installing SteamCMD

1. Create a directory for SteamCMD:
```bash
mkdir ~/Steam && cd ~/Steam
```

2. Download and extract SteamCMD for macOS:
```bash
curl -sqL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz" | tar zxvf -
```

3. Verify installation:
```bash
ls ~/Steam/steamcmd.sh
```

## 📚 Usage

### Steam Workshop Downloads

1. Click the **Workshop** button in the toolbar
2. Log in with your Steam credentials (supports Steam Guard Mobile Authenticator)
3. Paste a Steam Workshop URL (e.g., `https://steamcommunity.com/sharedfiles/filedetails/?id=2360329512`)
4. Click **Download & Extract**
5. Select which `.pkg` file to extract if multiple are found

## Local PKG Files

1. Click **Open PKG...** to browse for a local `.pkg` file
2. Browse the file tree to explore contents
3. Click **Export…** to choose a destination and select what to export (Images, Videos, Other files) and whether to flatten folders

## 🎯 Supported Formats

### Input
- `.pkg` - Wallpaper Engine package files
- `.tex` - Wallpaper Engine texture files (various formats)

### Output
- `.png` - Converted texture images
- `.mp4` - Extracted video files
- `.json`, `.vert`, `.frag` - Shader and configuration files (copied as-is)

## 🔧 Technical Details

### Texture Formats
- **RGBA8888** (Format 0): 32-bit color with alpha
- **DXT1** (Format 7): BC1 compression
- **DXT3** (Format 6): BC2 compression with explicit alpha
- **DXT5** (Format 4): BC3 compression with interpolated alpha
- **RG88** (Format 8): 2-channel textures
- **R8** (Format 9): Single-channel grayscale

### Container Versions
- **TEXB0001-0002**: Basic containers
- **TEXB0003**: With FreeImageFormat support
- **TEXB0004**: Enhanced format with MP4 support

## 💖 Support

If you find this tool useful, consider supporting development:

<a href="https://buymeacoffee.com/trinityhades" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

## 🙏 Credits

This project was inspired by [RePKG](https://github.com/notscuffed/repkg) by notscuffed, which provided invaluable insights into the Wallpaper Engine package format.

## 💻 Requirements

- macOS 15.1 or later
- SteamCMD (for Workshop downloads)
- Xcode 15.0+ (for building from source)
- Swift 5.9+

## 📃 License

Copyright 2025 Trinity Hades

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

See the [LICENSE](LICENSE) file for details.

## ⚠️ Disclaimer

This tool is not affiliated with or endorsed by Wallpaper Engine or Valve Corporation. Please respect content creators' rights and only extract content you have permission to use.

---

[Back to top](#top)
