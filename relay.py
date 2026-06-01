#!/usr/bin/env python3
"""TCP relay: reads size-prefixed frames from droneview-simulator, writes raw BGRA to stdout for FFmpeg."""
import socket, sys, struct

HOST = "127.0.0.1"
PORT = 9999

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)

# Retry connection until server is ready
import time
connected = False
for i in range(30):
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.connect((HOST, PORT))
        connected = True
        break
    except OSError as e:
        sock.close()
        if i == 0:
            print(f"relay: waiting for droneview TCP server on {HOST}:{PORT}...", file=sys.stderr)
        sys.stderr.write("."); sys.stderr.flush()
        time.sleep(1)

if not connected:
    print(f"\nrelay: could not connect to {HOST}:{PORT}", file=sys.stderr)
    sys.exit(1)

print(f"\nrelay: connected to {HOST}:{PORT}, streaming raw BGRA to stdout", file=sys.stderr)
sys.stderr.flush()

try:
    while True:
        # Read 4-byte big-endian frame size
        header = sock.recv(4)
        if len(header) < 4:
            break
        frame_size = struct.unpack(">I", header)[0]

        # Read the full frame
        data = bytearray()
        while len(data) < frame_size:
            chunk = sock.recv(frame_size - len(data))
            if not chunk:
                break
            data.extend(chunk)

        if len(data) == frame_size:
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
        else:
            break
except (BrokenPipeError, ConnectionResetError):
    pass
finally:
    sock.close()
