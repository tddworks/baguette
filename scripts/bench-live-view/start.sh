#!/bin/zsh
# Live-view bench: today's stream WebSocket next to a WHEP (WebRTC) spike, for one booted simulator.
# Design and results: docs/features/webrtc/design.md
#
#   scripts/bench-live-view/start.sh [--lan | --tailscale | --host <ip>] [--udid <UDID>]
#
# --lan   also serve the bench on this Mac's Wi-Fi/Ethernet address, so a phone on the same network can
#         open it. Anyone on that network can then drive the simulator through the proxy: use a trusted LAN.
#         A plain-http phone page has no WebCodecs, so its WebSocket run is MJPEG — as baguette serve gives it.
# --tailscale   the same on this Mac's Tailscale address, for a phone on your tailnet (works off Wi-Fi too).
# --host <ip>   the same on any address of this Mac.
# Needs: a built baguette (swift build -c release), mediamtx and ffmpeg (brew install mediamtx ffmpeg),
#        node, python3.
# Stop everything with scripts/bench-live-view/stop.sh.
set -eu
KIT=${0:a:h}; ROOT=${KIT:h:h}; RUN=$KIT/.run; mkdir -p $RUN
LAN=0; UDID=""; HOST=""
while (( $# )); do case $1 in
  --lan) LAN=1;;
  --tailscale) LAN=1; HOST=$(tailscale ip -4 2>/dev/null | head -1); [[ -n $HOST ]] || { echo "tailscale is not up" >&2; exit 1; };;
  --host) LAN=1; HOST=$2; shift;;
  --udid) UDID=$2; shift;;
  *) echo "unknown option $1" >&2; exit 2;;
esac; shift; done

BAGUETTE=$ROOT/.build/release/baguette
[[ -x $BAGUETTE ]] || { echo "build first: swift build -c release" >&2; exit 1; }
for tool in mediamtx ffmpeg python3 node; do command -v $tool >/dev/null || { echo "missing $tool (brew install mediamtx ffmpeg)" >&2; exit 1; }; done
[[ -n $UDID ]] || UDID=$(xcrun simctl list devices booted -j | python3 -c 'import json,sys; d=[x["udid"] for v in json.load(sys.stdin)["devices"].values() for x in v]; print(d[0] if d else "")')
[[ -n $UDID ]] || { echo "boot a simulator first (baguette boot --udid …), or pass --udid" >&2; exit 1; }

$KIT/stop.sh >/dev/null 2>&1 || true

if (( LAN )); then
  if [[ -z $HOST ]]; then
    IFACE=$(route -n get default | awk '/interface:/ {print $2}'); HOST=$(ipconfig getifaddr $IFACE)
    [[ -n $HOST ]] || { echo "no LAN address on $IFACE" >&2; exit 1; }
  fi
fi

# 1 · today's path: baguette serve (WebSocket stream + the input route both transports tap through)
nohup $BAGUETTE serve --host 127.0.0.1 --port 8421 > $RUN/serve.log 2>&1 &
echo $! > $RUN/serve.pid

# 2 · the WHEP server. Only RTSP in and WebRTC out; everything else off.
# The viewer's address is announced as an extra ICE candidate, so a tunnel interface (Tailscale) is reachable.
MTX_WEBRTCADDITIONALHOSTS=${HOST:-127.0.0.1} nohup mediamtx $KIT/mediamtx.yml > $RUN/mediamtx.log 2>&1 &
echo $! > $RUN/mediamtx.pid

# 3 · the WHEP source, started on demand by the proxy:
#     baguette stream (same encoder settings as serve) → Annex-B → RTSP → MediaMTX.
# stdin is held open: a stream whose stdin closes stops reading retune commands.
cat > $RUN/bridge.sh <<EOF
#!/bin/zsh
tail -f /dev/null | $BAGUETTE stream --udid $UDID --format avcc --fps 60 --bitrate 8000000 --scale 1 2>$RUN/stream.log \\
 | python3 -I $KIT/avcc2annexb.py \\
 | ffmpeg -hide_banner -loglevel warning -fflags nobuffer -flags low_delay -probesize 32 -analyzeduration 0 \\
     -use_wallclock_as_timestamps 1 -f h264 -i - -c copy -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/sim
EOF
chmod +x $RUN/bridge.sh

# 4 · one origin for pages, /api → serve, /whep → MediaMTX, /bridge/on|off.
# The proxy starts the bridge only for WebRTC runs: one encoder per run.
if (( LAN )); then
  nohup node $KIT/proxy.mjs --bridge $RUN/bridge.sh --listen $HOST > $RUN/proxy.log 2>&1 &
else
  nohup node $KIT/proxy.mjs --bridge $RUN/bridge.sh > $RUN/proxy.log 2>&1 &
fi
echo $! > $RUN/proxy.pid
sleep 2

# 5 · the probe target in the simulator
xcrun simctl openurl $UDID "http://127.0.0.1:8777/bench/fixture.html"
sleep 4

BASE="http://${HOST:-127.0.0.1}:8777"
echo "$UDID" > $RUN/udid
cat <<EOF
Live-view bench running for $UDID
  bench:               $BASE/bench/?udid=$UDID
  serve page (WS):     $BASE/devices/$UDID
  serve page (WebRTC): $BASE/devices/$UDID?transport=webrtc
  logs:                $RUN/
  stop:                $KIT/stop.sh
EOF
(( LAN )) && echo "  macOS may ask to allow incoming connections for node and mediamtx: allow them."
exit 0
