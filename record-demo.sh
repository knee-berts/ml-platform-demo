#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Record the preemption demo with asciinema + tmux
#
# Creates a tmux session with two panes:
#   Left:  demo-preemption.sh (interactive)
#   Right: load_test.py dashboard
#
# The asciinema recording captures the entire tmux session.
#
# Usage:
#   ./record-demo.sh                       # Record to preemption-demo.cast
#   ./record-demo.sh my-recording.cast     # Custom filename
#   ./record-demo.sh --gif                 # Record + generate GIF at 2x speed
#   ./record-demo.sh --upload              # Record + upload to asciinema.org
#   ./record-demo.sh --gif --upload        # All three
# ─────────────────────────────────────────────────────────────────────────────
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SESSION="demo-recording"

# Parse flags
GIF=false
UPLOAD=false
CAST_FILE=""
for arg in "$@"; do
  case "$arg" in
    --gif)    GIF=true ;;
    --upload) UPLOAD=true ;;
    *)        CAST_FILE="$arg" ;;
  esac
done
CAST_FILE="${CAST_FILE:-preemption-demo.cast}"
GIF_FILE="${CAST_FILE%.cast}.gif"

# Fix for terminals not recognized on remote hosts (e.g. Ghostty)
case "$TERM" in xterm-ghostty|*-unknown) export TERM=xterm-256color ;; esac

# Check dependencies
for cmd in asciinema tmux; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required but not installed."
    exit 1
  fi
done

# Kill any existing session with this name
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Terminal dimensions
# Dashboard needs: ~140 cols wide, ~80 rows tall (header 3 + clusters 14 + routing 9 + kueue flexible + stats 5)
# Demo script needs: ~80 cols wide
# Total: 80 + 1 (border) + 140 = 221 cols, 80 rows
COLS=221
ROWS=80
DEMO_WIDTH=80
DASH_WIDTH=$((COLS - DEMO_WIDTH - 1))  # 140

# Create the tmux session but don't attach yet
# Left pane: will run the demo script
tmux new-session -d -s "$SESSION" -x "$COLS" -y "$ROWS"

# Right pane: dashboard
tmux split-window -h -t "$SESSION" \
  "python3 '$SCRIPT_DIR/load_test.py' --mode dashboard --target-cluster east1; read -p 'Dashboard exited. Press Enter...'"

# Size panes: left = demo (80 cols), right = dashboard (140 cols)
tmux resize-pane -t "$SESSION:0.0" -x "$DEMO_WIDTH"

# Left pane: run the demo script
tmux send-keys -t "$SESSION:0.0" "'$SCRIPT_DIR/demo-preemption.sh'" Enter

# Record the tmux session with asciinema
echo "Recording to $CAST_FILE"
echo "  Terminal: ${COLS}x${ROWS}"
echo "  Left pane (${DEMO_WIDTH} cols):  demo-preemption.sh"
echo "  Right pane (${DASH_WIDTH} cols): load_test.py dashboard"
echo ""
echo "The demo is interactive — press Enter at each pause in the left pane."
echo "Press Ctrl-D or type 'exit' when done to stop recording."
echo ""

asciinema rec --overwrite "$CAST_FILE" \
  --cols "$COLS" --rows "$ROWS" \
  --title "Kueue Preemption Demo: Priority Scheduling on GPU Fleet" \
  --command "tmux attach -t $SESSION"

# Cleanup
tmux kill-session -t "$SESSION" 2>/dev/null || true
echo ""
echo "Recording saved to $CAST_FILE"
echo "Play back with: asciinema play $CAST_FILE"

# Upload if requested
if $UPLOAD; then
  echo ""
  TRIMMED_FILE="${CAST_FILE%.cast}-trimmed.cast"
  echo "Trimming cast (removing duplicate frames < 0.5s apart)..."
  python3 -c "
import json, sys

lines = open('$CAST_FILE').readlines()
header = lines[0]
events = []
for l in lines[1:]:
    l = l.strip()
    if not l:
        continue
    try:
        events.append(json.loads(l))
    except json.JSONDecodeError:
        continue

# Keep header + deduplicate: drop output events within 0.5s that have identical content
filtered = []
prev_time = -1
prev_content = ''
for ev in events:
    ts, etype, data = ev[0], ev[1], ev[2]
    if etype == 'o':
        if ts - prev_time < 0.5 and data == prev_content:
            continue
        prev_time = ts
        prev_content = data
    filtered.append(ev)

with open('$TRIMMED_FILE', 'w') as f:
    f.write(header)
    for ev in filtered:
        f.write(json.dumps(ev) + '\n')

orig = len(events)
kept = len(filtered)
print(f'  {orig} frames -> {kept} frames ({100*(orig-kept)//max(orig,1)}% reduction)')
"
  echo "Uploading trimmed cast to asciinema.org..."
  asciinema upload "$TRIMMED_FILE"
fi

# Generate GIF if requested
if $GIF; then
  echo ""
  AGG="$SCRIPT_DIR/../agg"
  if [ ! -x "$AGG" ]; then
    echo "Error: agg not found at $AGG"
    exit 1
  fi
  echo "Generating GIF at 2x speed..."
  "$AGG" --speed 2 "$CAST_FILE" "$GIF_FILE"
  echo ""
  echo "GIF saved to $GIF_FILE"
  FULL_GIF_PATH="$(cd "$(dirname "$GIF_FILE")" && pwd)/$(basename "$GIF_FILE")"
  INSTANCE_NAME=$(hostname)
  ZONE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone 2>/dev/null | awk -F/ '{print $NF}')
  PROJECT=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id 2>/dev/null)
  echo ""
  echo "To download to your Mac, run from your local terminal:"
  echo ""
  echo "  gcloud compute scp ${INSTANCE_NAME}:${FULL_GIF_PATH} ~/Downloads/ --zone=${ZONE} --project=${PROJECT} --tunnel-through-iap"
  echo ""
fi
