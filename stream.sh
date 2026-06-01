#!/bin/bash
set -e

cd "$(dirname "$0")"

# ── Config ──────────────────────────────────────────
RTSP_PORT=8554       # MediaMTX RTSP port
RTMP_PORT=1935       # MediaMTX RTMP port
STREAM_PATH="drone"  # stream name → rtsp://localhost:8554/drone
FPS=30
BITRATE="4M"     # higher bitrate for full-resolution streaming
STREAM_W=1280    # Retina drawable resolution (change to 640 for non-Retina)
STREAM_H=1280
# ────────────────────────────────────────────────────

echo "═══════════════════════════════════════════"
echo "🛸  DroneView RTSP Streamer"
echo "═══════════════════════════════════════════"

# Cleanup on exit
cleanup() {
    echo ""
    echo "🛑 Shutting down..."
    [ -n "$MEDIAMTX_PID" ] && kill "$MEDIAMTX_PID" 2>/dev/null || true
    [ -n "$FFMPEG_PID" ] && kill "$FFMPEG_PID" 2>/dev/null || true
    [ -n "$DRONE_PID" ] && kill "$DRONE_PID" 2>/dev/null || true
    wait 2>/dev/null || true
    echo "✅ Done."
}
trap cleanup EXIT INT TERM

# 1. Start MediaMTX
echo "📡 Starting MediaMTX server..."
./mediamtx &
MEDIAMTX_PID=$!
sleep 2

# Wait for MediaMTX to be ready
for i in $(seq 1 10); do
    if curl -s http://localhost:9997 > /dev/null 2>&1; then
        break
    fi
    sleep 1
done
echo "   MediaMTX PID: $MEDIAMTX_PID"

# 2. Start droneview-simulator (starts TCP stream server on port 9999)
echo "🎮 Starting DroneView Simulator (streaming mode)..."
./droneview-simulator --stream &
DRONE_PID=$!
echo "   DroneView PID: $DRONE_PID"
sleep 3  # Give the TCP server time to bind and listen

# 3. relay.py connects to TCP, strips framing, outputs raw BGRA to stdout
# 4. FFmpeg: reads raw BGRA from relay → encode H.264 → push RTMP to MediaMTX
echo "🎥 Starting relay + FFmpeg encoder (BGRA → H.264 → RTMP)..."
# Stream at full Retina resolution (1280×1280) — no downscaling.
python3 relay.py | ffmpeg \
    -f rawvideo \
    -pixel_format bgra \
    -video_size ${STREAM_W}x${STREAM_H} \
    -framerate $FPS \
    -use_wallclock_as_timestamps 1 \
    -i pipe:0 \
    -c:v libx264 \
    -preset ultrafast \
    -tune zerolatency \
    -b:v $BITRATE \
    -maxrate $BITRATE \
    -bufsize 2M \
    -g 30 \
    -keyint_min 30 \
    -profile:v baseline \
    -level 3.2 \
    -pix_fmt yuv420p \
    -f flv \
    "rtmp://localhost:$RTMP_PORT/$STREAM_PATH" &
FFMPEG_PID=$!
echo "   FFmpeg PID: $FFMPEG_PID"

# ── Detect local IP ────────────────────────────────
# Try en0 (Wi-Fi) first, then en1 (Ethernet / Thunderbolt)
LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "unknown")
if [ "$LOCAL_IP" = "unknown" ]; then
    # fallback: use ifconfig to find first non-loopback IPv4
    LOCAL_IP=$(ifconfig | awk '/inet / && $2 !~ /^127\./ {print $2; exit}')
fi
[ -z "$LOCAL_IP" ] && LOCAL_IP="unknown"

echo "   Local IP: $LOCAL_IP"

echo ""
echo "═══════════════════════════════════════════"
echo "✅ STREAMING!"
echo ""
echo "   Resolution: ${STREAM_W}×${STREAM_H} @ ${FPS}fps  (H.264 baseline, ${BITRATE})"
echo ""
echo "   RTSP:  rtsp://$LOCAL_IP:$RTSP_PORT/$STREAM_PATH"
echo "          rtsp://localhost:$RTSP_PORT/$STREAM_PATH"
echo ""
echo "   View with VLC:"
echo "     vlc rtsp://$LOCAL_IP:$RTSP_PORT/$STREAM_PATH"
echo ""
echo "   Press Ctrl+C to stop."
echo "═══════════════════════════════════════════"

# Wait for any process to exit
wait
