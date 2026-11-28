#!/usr/bin/env bash
set -Eeuo pipefail

: "${TARGET_URL:?TARGET_URL is required}"
: "${YOUTUBE_STREAM_KEY:?Add YOUTUBE_STREAM_KEY in GitHub repository secrets}"
: "${GH_HANDOVER_TOKEN:?Add GH_HANDOVER_TOKEN in GitHub repository secrets}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}"
: "${VIDEO_WIDTH:=1920}"
: "${VIDEO_HEIGHT:=1080}"
: "${FPS:=30}"
: "${SESSION_MINUTES:=15}"
: "${HANDOVER_LEAD_MINUTES:=5}"
: "${HANDOVER_ROLE:=ACTIVE}"
: "${HANDOVER_SESSION_ID:=}"

if [[ ! "$YOUTUBE_STREAM_KEY" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "Stream key contains unexpected characters; refusing to continue."
  exit 1
fi

if [[ ! "$GH_HANDOVER_TOKEN" ]]; then
  echo "GH_HANDOVER_TOKEN is empty."
  exit 1
fi

PLAYWRIGHT_DIR="$HOME/.local/pids-live/node_modules/playwright"
if [[ ! -d "$PLAYWRIGHT_DIR" ]]; then
  echo "Cached Playwright package is missing. Run the workflow installation step first."
  exit 1
fi

CHROME="$(node -e "console.log(require(process.env.HOME + '/.local/pids-live/node_modules/playwright').chromium.executablePath())")"
if [[ ! -x "$CHROME" ]]; then
  echo "Cached Chromium executable is missing: $CHROME"
  exit 1
fi

API_BASE="https://api.github.com/repos/$GITHUB_REPOSITORY"
VARIABLE_URL="$API_BASE/actions/variables/PIDS_HANDOVER_STATE"
api_headers=(-H "Accept: application/vnd.github+json" -H "Authorization: Bearer $GH_HANDOVER_TOKEN" -H "X-GitHub-Api-Version: 2022-11-28")

get_handover_state() {
  curl --silent --show-error --fail "${api_headers[@]}" "$VARIABLE_URL" | jq -r '.value // ""'
}

set_handover_state() {
  local value="$1"
  local payload
  payload="$(jq -nc --arg name "PIDS_HANDOVER_STATE" --arg value "$value" '{name:$name,value:$value}')"
  local code
  code="$(curl --silent --show-error "${api_headers[@]}" -o /tmp/pids-variable-response.json -w '%{http_code}' -X PATCH -H 'Content-Type: application/json' --data "$payload" "$VARIABLE_URL")"
  if [[ "$code" == "404" ]]; then
    curl --silent --show-error --fail "${api_headers[@]}" -X POST -H 'Content-Type: application/json' --data "$payload" "$API_BASE/actions/variables" >/dev/null
  elif [[ "$code" != "204" ]]; then
    cat /tmp/pids-variable-response.json
    echo "Failed to update handover variable (HTTP $code)."
    return 1
  fi
}

dispatch_prepare() {
  local session_id="$1"
  local payload
  payload="$(jq -nc --arg ref "$GITHUB_REF_NAME" --arg session_id "$session_id" '{ref:$ref,inputs:{session_id:$session_id}}')"
  curl --silent --show-error --fail "${api_headers[@]}" -X POST -H 'Content-Type: application/json' --data "$payload" "$API_BASE/actions/workflows/prepare.yml/dispatches" >/dev/null
}

dispatch_fallback() {
  local payload
  payload="$(jq -nc --arg ref "$GITHUB_REF_NAME" '{ref:$ref}')"
  curl --silent --show-error --fail "${api_headers[@]}" -X POST -H 'Content-Type: application/json' --data "$payload" "$API_BASE/actions/workflows/live.yml/dispatches" >/dev/null
}

# Prepare the virtual audio output and display server.
export XDG_RUNTIME_DIR="${RUNNER_TEMP:-/tmp}/pids-audio-runtime"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
pulseaudio --kill 2>/dev/null || true
pulseaudio --start --exit-idle-time=-1 --log-target=stderr
pactl load-module module-null-sink sink_name=pids_sink sink_properties=device.description=PIDS_Audio
pactl set-default-sink pids_sink
AUDIO_SOURCE="pids_sink.monitor"

export DISPLAY=:99
Xvfb "$DISPLAY" -screen 0 "${VIDEO_WIDTH}x${VIDEO_HEIGHT}x24" -ac +extension RANDR &
XVFB_PID=$!
FFMPEG_PID=""
BROWSER_PID=""

cleanup() {
  set +e
  [[ -n "$FFMPEG_PID" ]] && kill "$FFMPEG_PID" 2>/dev/null
  [[ -n "$BROWSER_PID" ]] && kill "$BROWSER_PID" 2>/dev/null
  [[ -n "$XVFB_PID" ]] && kill "$XVFB_PID" 2>/dev/null
  pulseaudio --kill 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT INT TERM

sleep 3
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
LEAD_SECONDS=$((HANDOVER_LEAD_MINUTES * 60))
PREPARE_AT=$((DURATION_SECONDS - LEAD_SECONDS))

start_ffmpeg() {
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
    -f pulse \
    -i "$AUDIO_SOURCE" \
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
}

if [[ "$HANDOVER_ROLE" == "PREPARE" ]]; then
  if [[ -z "$HANDOVER_SESSION_ID" ]]; then
    echo "HANDOVER_SESSION_ID is required for PREPARE role."
    exit 1
  fi
  echo "Prepared worker is ready; waiting for handover signal."
  set_handover_state "$HANDOVER_SESSION_ID:READY"
  READY_DEADLINE=$((SECONDS + 600))
  until [[ "$(get_handover_state)" == "$HANDOVER_SESSION_ID:GO" ]]; do
    if (( SECONDS >= READY_DEADLINE )); then
      echo "Timed out waiting for handover GO signal."
      exit 1
    fi
    sleep 3
  done
  echo "Handover received; starting FFmpeg."
  start_ffmpeg
else
  start_ffmpeg
fi

STARTED_AT=$SECONDS
while (( SECONDS - STARTED_AT < PREPARE_AT )); do
  if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
    wait "$FFMPEG_PID"
    echo "FFmpeg exited before handover window."
    exit 1
  fi
  sleep 5
done

NEXT_SESSION_ID="${GITHUB_RUN_ID:-manual}-${GITHUB_RUN_ATTEMPT:-1}-$(date +%s)"
echo "Dispatching prepared worker: $NEXT_SESSION_ID"
if ! dispatch_prepare "$NEXT_SESSION_ID"; then
  echo "Could not dispatch prepare worker; continuing current stream until its limit."
  while kill -0 "$FFMPEG_PID" 2>/dev/null; do sleep 5; done
  wait "$FFMPEG_PID"
  dispatch_fallback
  exit 0
fi

READY_DEADLINE=$((SECONDS + 240))
READY=0
while (( SECONDS < READY_DEADLINE )); do
  if [[ "$(get_handover_state 2>/dev/null || true)" == "$NEXT_SESSION_ID:READY" ]]; then
    READY=1
    break
  fi
  if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
    wait "$FFMPEG_PID"
    echo "Current FFmpeg ended while waiting for the next worker."
    exit 1
  fi
  sleep 3
done

if (( READY )); then
  echo "Next worker is ready; stopping current FFmpeg before releasing it."
  kill "$FFMPEG_PID"
  wait "$FFMPEG_PID" || true
  FFMPEG_PID=""
  set_handover_state "$NEXT_SESSION_ID:GO"
  echo "Handover signal sent."
  exit 0
fi

echo "Next worker did not become ready in time; retaining current stream."
while kill -0 "$FFMPEG_PID" 2>/dev/null; do sleep 5; done
wait "$FFMPEG_PID"
dispatch_fallback
echo "Fallback live worker queued."
