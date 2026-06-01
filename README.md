# 🛸 DroneView Simulator

A Metal-based top-down terrain viewer written in Swift. Navigate a grid of aerial images as if flying a drone — pan, zoom, and stream the view over RTSP.

## Features

- **Top-down drone view** — Navigate a ground plane of image tiles with smooth camera movement
- **WASD / Arrow key movement** — Pan across the terrain at speed proportional to altitude
- **H / L altitude control** — Zoom in for detail or out for overview (0.3–25+ world units)
- **C key camera reset** — Instantly return to the starting position
- **Real-time HUD overlay** — Camera position (X, Z), altitude, and FPS displayed on screen
- **Procedural fallback** — Generates colorful grid tiles when no images are found
- **RTSP live streaming** — Broadcast the Metal viewport as an RTSP video stream via TCP relay + FFmpeg

## Requirements

- **macOS** (AppKit + Metal required)
- **Swift 5** toolchain (Xcode or command-line tools)
- Optional streaming dependencies:
  - [MediaMTX](https://github.com/bluenviron/mediamtx) (RTSP server)
  - Python 3 (TCP relay)
  - FFmpeg (H.264 encoding)

## Quick Start

### 1. Build

```bash
bash build.sh
```

This compiles `Sources/main.swift` into `./droneview-simulator` using the Metal, MetalKit, and AppKit frameworks.

### 2. Prepare Images (optional)

Place JPEG or PNG images in a folder named `images/` next to the binary. Images are sorted alphabetically and arranged in a square-ish grid.

```
droneview/
├── images/
│   ├── tile_001.jpg
│   ├── tile_002.jpg
│   └── ...
├── droneview-simulator
└── ...
```

If no images are found, 16 procedural colored tiles are generated automatically.

### 3. Run

```bash
./droneview-simulator
```

A 640×640 window opens centered on screen with the tile grid visible.

## Controls

| Key(s)       | Action                        |
|-------------|-------------------------------|
| `W` / `↑`   | Move forward (north / +Z)     |
| `S` / `↓`   | Move backward (south / −Z)    |
| `A` / `←`   | Move left (west / −X)         |
| `D` / `→`   | Move right (east / +X)        |
| `H`         | Increase altitude (zoom out)  |
| `L`         | Decrease altitude (zoom in)   |
| `C`         | **Reset camera** to start position |
| `⌘Q`        | Quit                          |

Movement speed scales with altitude — you cover more ground when zoomed out.

### HUD Overlay

The bottom-left corner of the window displays:

```
Camera: (X.XX, Z.ZZ)  |  Altitude: X.XX  |  FPS: 60
```

- **Camera** — Current X and Z world coordinates
- **Altitude** — Height above ground (lower = more zoomed in)
- **FPS** — Smoothed frames-per-second (rolling average over ~60 frames)

## RTSP Streaming

Stream the Metal viewport as a live RTSP video feed viewable in VLC or any RTSP client.

### Architecture

```
┌──────────────────┐     TCP (port 9999)     ┌──────────┐     raw BGRA     ┌───────┐     RTMP     ┌──────────┐     RTSP     ┌─────────┐
│ droneview-sim    │ ───────────────────────→ │ relay.py │ ──────────────→ │ FFmpeg │ ──────────→ │ MediaMTX │ ───────────→ │ VLC/etc │
│ (--stream flag)  │   size-prefixed frames   │          │   pipe stdout   │        │   H.264        │          │            │         │
└──────────────────┘                         └──────────┘                  └───────┘                └──────────┘            └─────────┘
```

### Start Streaming

```bash
bash stream.sh
```

This script:
1. Starts **MediaMTX** (RTSP/RTMP server on ports 8554/1935)
2. Starts `droneview-simulator --stream` (TCP server on port 9999)
3. Runs `relay.py` → **FFmpeg** to encode BGRA frames to H.264 and push to RTMP

### View the Stream

```bash
vlc rtsp://localhost:8554/drone
```

Or from another device on the same network (the script prints the local IP):

```bash
vlc rtsp://192.168.x.x:8554/drone
```

### Stream Configuration

Edit `stream.sh` to adjust:

| Variable       | Default  | Description                        |
|---------------|----------|------------------------------------|
| `STREAM_W/H`  | 1280     | Output resolution (Retina native)  |
| `FPS`         | 30       | Stream frame rate                  |
| `BITRATE`     | 4M       | H.264 encoding bitrate             |
| `RTSP_PORT`   | 8554     | MediaMTX RTSP port                 |
| `STREAM_PATH` | `drone`  | Stream path name                   |

## Tuning

Key parameters are marked with `CHANGE:` comments in `Sources/main.swift`:

| Parameter              | Location       | Default | Effect                                |
|-----------------------|----------------|---------|---------------------------------------|
| Starting altitude     | `Renderer.init` | `minAlt × 3` | Initial zoom level             |
| View scale            | `draw()`       | 1.8     | Zoom factor (higher = more zoomed out)  |
| Altitude range        | `setupGround()` | auto    | Min/max altitude based on ground size |
| Movement speed        | `update()`     | 0.5×alt | How fast camera pans                  |
| Altitude change speed | `update()`     | 1.5     | How fast H/L zoom                     |
| Camera smoothness     | `update()`     | 12.0    | Lerp exponent (higher = snappier)     |

## Project Structure

```
droneview/
├── Sources/
│   └── main.swift          # Full application (renderer, HUD, controls, streaming server)
├── images/                 # Tile images (JPEG/PNG), optional
├── build.sh                # Swift compilation script
├── stream.sh               # RTSP streaming pipeline launcher
├── relay.py                # TCP → stdout relay for FFmpeg
├── mediamtx                # MediaMTX binary (RTSP server)
├── mediamtx.yml            # MediaMTX configuration
└── README.md
```

## License

This project is provided as-is for simulation and prototyping purposes.
