#!/usr/bin/env bash
set -Eeuo pipefail

: "${TARGET_URL:?TARGET_URL is required}"
: "${YOUTUBE_STREAM_KEY:?Add YOUTUBE_STREAM_KEY in GitHub repository secrets}"
: "${VIDEO_WIDTH:=1920}"
: "${VIDEO_HEIGHT:=1080}"
: "${FPS:=30}"
: "${SESSION_MINUTES:=345}"

if [[ ! "$YOUTUBE_STREAM_KEY" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "Stream key contains unexpected characters; refusing to continue."
  exit 1
fi

export DISPLAY=:99
Xvfb "$DISPLAY" -screen 0 "${VIDEO_WIDTH}x${VIDEO_HEIGHT}x24" -ac +extension RANDR &
XVFB_PID=$!

cleanup() {
  set +e
  [[ -n "${FFMPEG_PID:-}" ]] && kill "$FFMPEG_PID" 2>/dev/null
  [[ -n "${BROWSER_PID:-}" ]] && kill "$BROWSER_PID" 2>/dev/null
  kill "$XVFB_PID" 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT INT TERM

sleep 3

CHROME="$(command -v chromium-browser || command -v chromium || true)"
if [[ -z "$CHROME" ]]; then
  echo "Chromium executable not found."
  exit 1
fi

"$CHROME" \
  --no-sandbox \
  --disable-dev-shm-usage \
  --disable-gpu \
  --disable-background-timer-throttling \
  --disable-renderer-backgrounding \
  --disable-backgrounding-occluded-windows \
  --autoplay-policy=no-user-gesture-required \
  --no-first-run \
  --disable-infobars \
  --kiosk \
  --window-size="${VIDEO_WIDTH},${VIDEO_HEIGHT}" \
  "$TARGET_URL" &
BROWSER_PID=$!

echo "Waiting for the PIDS page to render..."
sleep 25

RTMP_URL="rtmps://a.rtmps.youtube.com:443/live2/${YOUTUBE_STREAM_KEY}"
DURATION_SECONDS=$((SESSION_MINUTES * 60))

ffmpeg \
  -hide_banner \
  -loglevel warning \
  -stats \
  -thread_queue_size 512 \
  -f x11grab \
  -draw_mouse 0 \
  -framerate "$FPS" \
  -video_size "${VIDEO_WIDTH}x${VIDEO_HEIGHT}" \
  -i "${DISPLAY}.0" \
  -f lavfi \
  -i "anullsrc=channel_layout=stereo:sample_rate=44100" \
  -t "$DURATION_SECONDS" \
  -map 0:v:0 \
  -map 1:a:0 \
  -c:v libx264 \
  -preset veryfast \
  -tune zerolatency \
  -pix_fmt yuv420p \
  -r "$FPS" \
  -g "$((FPS * 2))" \
  -b:v 4500k \
  -maxrate 4500k \
  -bufsize 9000k \
  -c:a aac \
  -b:a 128k \
  -ar 44100 \
  -f flv \
  "$RTMP_URL" &
FFMPEG_PID=$!

# Fail the job if FFmpeg exits unexpectedly; otherwise stop cleanly at the
# configured session limit so the next scheduled job can take over.
for ((i=0; i<DURATION_SECONDS; i+=10)); do
  if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
    wait "$FFMPEG_PID"
    echo "FFmpeg exited before the session limit."
    exit 1
  fi
  sleep 10
done

echo "Session limit reached; ending this encoder session."
