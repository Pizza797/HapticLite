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
- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
- [License](#license)

## Features
- Runs locally
- Haptic waveforms for left, right and middle clicks
- Optional feedback for scrolling with adjustable spacing
- Hold feedback: replays a waveform while a button is held and stops on release
- Per-app profiles, plus a default profile for all other apps/windows
- Per-app windows pointer speed setting

## Installation

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
