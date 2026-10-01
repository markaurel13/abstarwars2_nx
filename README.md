<div align="center">

<img src="launcher/icon.jpg" alt="Angry Birds Star Wars II" width="160">

# abstarwars2_nx

**Angry Birds Star Wars II for Nintendo Switch**

An unofficial Nintendo Switch native wrapper for the 32-bit Android release of  
**Angry Birds Star Wars II**.

[![Nintendo Switch](https://img.shields.io/badge/Nintendo_Switch-Homebrew-E60012?style=for-the-badge&logo=nintendoswitch&logoColor=white)](#)
[![Version](https://img.shields.io/badge/Version-1.0.0-4C8BF5?style=for-the-badge)](#)
[![Architecture](https://img.shields.io/badge/AArch32-32--bit_Native-6A1B9A?style=for-the-badge)](#)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg?style=for-the-badge)](LICENSE)

</div>

---

## About

`abstarwars2_nx` is a native wrapper that runs the 32-bit ARM Android build of **Angry Birds Star Wars II** on Nintendo Switch. 

It loads the game's original `libAngryBirdsStarWarsII.so` (powered by Rovio's **Fusion engine**, Lua 5.1 and Box2D) and recreates the Android, JNI, libc, audio, input, and graphics environments that the library expects under Horizon OS.

Because the Tegra X1 CPU in the Nintendo Switch natively supports 32-bit ARM (AArch32) execution, the game code runs **directly on the hardware with full native speed**—no CPU emulation is involved.

> [!NOTE]
> **No game code or assets are included in this repository.**  
> Users must supply their own legitimate copy of the game's APK.

---

## Features

- **Full Native Performance:** Runs natively on the Switch ARM Cortex-A57 CPU in AArch32 mode.
- **Hardware-Accelerated Graphics:** Uses OpenGL ES 2.0 via `mesa32` (Nouveau) for crisp 720p/1080p rendering.
- **Touchscreen & Controller Support:** Full touch screen controls as on mobile, plus controller / hand cursor support.
- **Atmosphère & Sphaira Integration:** Features a dedicated launcher NRO that registers a HOME menu forwarder icon.

---

## Requirements

### For Players
- A Nintendo Switch running **Atmosphère** custom firmware.
- The [Sphaira](https://github.com/ITotalJustice/sphaira) homebrew menu (recommended for installing the forwarder).
- A copy of **Angry Birds Star Wars II.apk** (v1.9.25, no modified)
- The folder `data/files/` known as just the "assets" (required because Rovio's original online download servers were discontinued and the apk does not contain the assets).

---

## Installation Guide

1. Download the latest release from the [Releases](#) tab:
   - `abstarwars2_nx.nro`
2. On your Switch SD card, create the following directory:
   ```text
   sdmc:/switch/abstarwars2/
   ```
3. Place your APK and your assets files inside that folder:
   - Copy `abstarwars2_nx.nro` into `sdmc:/switch/abstarwars2/`.
   - Copy your `angry-birds-star-wars-ii-1-9-25.apk` into `sdmc:/switch/abstarwars2/` (the name of the apk does not matter).
   - Paste your `data/files` directory into `sdmc:/switch/abstarwars2/`.
4. The final folder structure on your SD card must look like:
   ```text
   sdmc:/switch/abstarwars2/
   ├── abstarwars2_nx.nro
   ├── angry-birds-star-wars-ii-1-9-25.apk
   └── data/
       └── files/
           ├── assets_service/
           ├── settings.lua
           ├── fusion.registry
           └── ...
   ```
5. Launch **Sphaira** on your Switch:
   - Navigate to **Homebrew** › **Angry Birds Star Wars II**.
   - Choose **Install Forwarder**.
   - Return to the Switch HOME Menu and launch the game directly from its icon!

---

## Controls

| Input | Action |
| :--- | :--- |
| **Touchscreen** | Direct touch controls (identical to the mobile version) |
| **Left Stick** | Hand cursor movement / aiming |
| **A / ZL / ZR** | Touch / Slingshot pull & release |
| **B** | Back / Cancel |
| **+ (Plus)** | Pause / Resume |

---

## Building from Source

### Prerequisites
- Linux (Ubuntu / Debian / Linux Mint recommended)
- **Docker**
- Git

### Build Instructions

1. **Clone the repository with submodules:**
   ```bash
   git clone --recursive https://github.com/YOUR_USERNAME/abstarwars2_nx.git
   cd abstarwars2_nx
   ```

2. **Pull the required Docker toolchains:**
   ```bash
   docker pull ghcr.io/vita2hos/devcontainer/vita2hos
   docker pull devkitpro/devkita64
   ```

3. **Set up `libnx32` and `mesa32`:**
   - Compile `libnx32`:
     ```bash
     git clone https://github.com/aks796/libnx32.git
     ./libnx32/build.sh
     ```
   - Download the prebuilt `mesa32` release into `portlibs32/`:
     ```bash
     mkdir -p portlibs32
     wget https://github.com/aks796/mesa32/releases/download/mesa-20.1.0-rc3/mesa32.zip -O /tmp/mesa32.zip
     unzip -q /tmp/mesa32.zip -d portlibs32/
     ```

4. **Compile the 32-bit program:**
   ```bash
   ./build.sh
   ```

5. **Compile the 64-bit launcher NRO:**
   ```bash
   launcher/build.sh
   ```
   The compiled launcher will be located at `launcher/abstarwars2_nx.nro`.

---

## Credits & Acknowledgments

- **Rovio Entertainment & Lucasfilm**: Original creators of Angry Birds Star Wars II.
- **[aks796](https://github.com/aks796)**: For the groundbreaking [`android32`](https://github.com/aks796/android32) runtime, [`libnx32`](https://github.com/aks796/libnx32), [`mesa32`](https://github.com/aks796/mesa32), and the [`abspace_nx`](https://github.com/aks796/abspace_nx) reference port
- **Andy Nguyen (TheOfficialFloW) & fgsfds**: Dynamic `.so` loader implementations.
- **xerpi**: For `vita2hos`, pioneer of AArch32 native execution on Switch.
- **Switchbrew**: For `libnx` and tools.

---

## License

This project is licensed under the [MIT License](LICENSE).
Angry Birds Star Wars II is a registered trademark of Rovio Entertainment and Lucasfilm Ltd. This project is not affiliated with or endorsed by Rovio or Lucasfilm.
