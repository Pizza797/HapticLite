<p align="center">
  <img src="assets/logo.png" alt="Project logo" width="200">
</p>

<h1 align="center">HapticLite</h1>

<p align="center">
  Open-source Haptic feedback control for the Logitech MX Master 4.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/license-GPLv3-blue" alt="License">
  <img src="https://img.shields.io/github/last-commit/Pizza797/HapticLite" alt="Last commit">
  <img src="https://img.shields.io/badge/python-3.11+-blue" alt="Python">
</p>

---

## Table of Contents
- [How it works](#how_it_works)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [License](#license)

## How it works

Logitech's Logi Options+ app loads a plugin called HapticWeb, which lets other programs trigger the mouse's haptic waveforms over a local web address. 

HapticLite watches your mouse buttons and the active app and asks HapticWeb to play the waveform you chose. 

*Note: HapticLite does not communicate with the mouse directly and does not replace the Options+ app.*

## Features
- Runs locally (Has a browser settings page)
- Haptic waveforms for left, right and middle clicks
- Optional feedback for scrolling with adjustable spacing
- Hold feedback: replays a waveform while a button is held and stops on release
- Per-app profiles, plus a default profile for all other apps/windows
- Per-app windows pointer speed setting

## Requirements
- Windows machine (Windows 10/11)
- Logitech MX Master 4 mouse
- Logi Options+ app (tested on version 1.83)
- The HapticWeb plugin (https://haptics.jmw.nz/), this will need to be installed in Options+ as a plugin
- Python 3.12 (or higher)

## Installation

*Note: I recommend installing HapticLite in a normal PowerShell window and not as admin. If installed as an admin it will show a UAC prompt after each startup* 

1. Make sure you have Options+ installed [Download Options+](https://www.logitech.com/en-us/software/logi-options-plus)
2. Install the HapticWeb plugin in Options+ 
  - Options+ > Buttons 
  - Click "Show actions ring" > 
  - Click "Configure action ring" > 
  - Click on the Marketplace icon (Top right corner) and search for HapticWeb by Jasper M-W
  <img src="assets/HapticWeb Plugin.png"

```bash
git clone https://github.com/USERNAME/REPO.git
cd REPO
pip install -r requirements.txt
```

## Usage

```python
import mypackage

mypackage.run()
```

// | Option | Description | Default |
// |--------|-------------|---------|
// | `--port` | Port to listen on | `8080` |
// | `--debug` | Enable debug logging | `false` |

## Screenshots
![Screenshot](assets/screenshot.png)

## License
Distributed under the MIT License. See [LICENSE](LICENSE) for details.
