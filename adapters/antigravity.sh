#!/bin/bash
# peon-ping adapter for Google Antigravity IDE
# Watches ~/.gemini/antigravity/brain/ for agent state changes
# and translates them into peon.sh CESP events.
#
# Requires: fswatch (macOS: brew install fswatch) or inotifywait (Linux: apt install inotify-tools)
# Requires: peon-ping already installed
#
# Usage:
#   bash ~/.claude/hooks/peon-ping/adapters/antigravity.sh        # foreground
#   bash ~/.claude/hooks/peon-ping/adapters/antigravity.sh &      # background

set -euo pipefail

PEON_DIR="${CLAUDE_PEON_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/peon-ping}"
BRAIN_DIR="${ANTIGRAVITY_BRAIN_DIR:-$HOME/.gemini/antigravity/brain}"

# --- Colors ---
BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RESET=$'\033[0m'

info()  { printf "%s>%s %s\n" "$GREEN" "$RESET" "$*"; }
warn()  { printf "%s!%s %s\n" "$YELLOW" "$RESET" "$*"; }
error() { printf "%sx%s %s\n" "$RED" "$RESET" "$*" >&2; }

# --- Preflight ---
if [ ! -f "$PEON_DIR/peon.sh" ]; then
  error "peon.sh not found at $PEON_DIR/peon.sh"
  error "Install peon-ping first: curl -fsSL peonping.com/install | bash"
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  error "python3 is required but not found."
  exit 1
fi

# Detect filesystem watcher
WATCHER=""
if command -v fswatch &>/dev/null; then
  WATCHER="fswatch"
elif command -v inotifywait &>/dev/null; then
  WATCHER="inotifywait"
else
  error "No filesystem watcher found."
  error "  macOS: brew install fswatch"
  error "  Linux: apt install inotify-tools"
  exit 1
fi

if [ ! -d "$BRAIN_DIR" ]; then
  warn "Antigravity brain directory not found: $BRAIN_DIR"
  warn "Waiting for Antigravity to create it..."
  while [ ! -d "$BRAIN_DIR" ]; do
    sleep 2
  done
  info "Brain directory detected."
fi

# --- State: track known GUIDs and their last-seen artifact type ---
declare -A KNOWN_GUIDS  # GUID -> last artifact type seen (task|implementation_plan|walkthrough)

# --- Emit a peon.sh event ---
emit_event() {
  local event="$1"
  local guid="$2"
  local session_id="antigravity-${guid:0:8}"

  echo "{\"hook_event_name\":\"$event\",\"notification_type\":\"\",\"cwd\":\"$PWD\",\"session_id\":\"$session_id\",\"permission_mode\":\"\"}" \
    | bash "$PEON_DIR/peon.sh" 2>/dev/null || true
}

# --- Parse a metadata file and determine event ---
handle_metadata_change() {
  local filepath="$1"

  # Extract GUID from path: .../brain/<GUID>/file.metadata.json
  local guid
  guid=$(python3 -c "
import sys, os
parts = sys.argv[1].split(os.sep)
# Find 'brain' in path, GUID is next element
for i, p in enumerate(parts):
    if p == 'brain' and i + 1 < len(parts):
        print(parts[i + 1])
        break
" "$filepath" 2>/dev/null) || return

  [ -z "$guid" ] && return

  # Parse metadata to get artifact type
  local artifact_type
  artifact_type=$(python3 -c "
import sys, json
try:
    meta = json.load(open(sys.argv[1]))
    at = meta.get('artifactType', '')
    # Strip prefix: ARTIFACT_TYPE_TASK -> task
    at = at.replace('ARTIFACT_TYPE_', '').lower()
    print(at)
except:
    pass
" "$filepath" 2>/dev/null) || return

  [ -z "$artifact_type" ] && return

  local prev="${KNOWN_GUIDS[$guid]:-}"

  case "$artifact_type" in
    task)
      if [ -z "$prev" ]; then
        # New task = new session
        KNOWN_GUIDS[$guid]="task"
        info "New agent session: ${guid:0:8}"
        emit_event "SessionStart" "$guid"
      fi
      ;;
    implementation_plan)
      if [ "$prev" != "implementation_plan" ] && [ "$prev" != "walkthrough" ]; then
        # Moved to execution phase
        KNOWN_GUIDS[$guid]="implementation_plan"
        info "Agent working: ${guid:0:8}"
        emit_event "UserPromptSubmit" "$guid"
      fi
      ;;
    walkthrough)
      if [ "$prev" != "walkthrough" ]; then
        # Moved to verification = task complete
        KNOWN_GUIDS[$guid]="walkthrough"
        info "Agent completed: ${guid:0:8}"
        emit_event "Stop" "$guid"
      fi
      ;;
  esac
}

# --- Cleanup ---
cleanup() {
  info "Stopping Antigravity watcher..."
  # Kill any child processes (fswatch/inotifywait)
  kill 0 2>/dev/null
  exit 0
}
trap cleanup SIGINT SIGTERM

# --- Test mode: skip main loop when sourced for testing ---
if [ "${PEON_ADAPTER_TEST:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# --- Start watching ---
info "${BOLD}peon-ping Antigravity adapter${RESET}"
info "Watching: $BRAIN_DIR"
info "Watcher: $WATCHER"
info "Press Ctrl+C to stop."
echo ""

if [ "$WATCHER" = "fswatch" ]; then
  # Use process substitution to avoid subshell (preserves KNOWN_GUIDS state)
  while read -r changed_file; do
    handle_metadata_change "$changed_file"
  done < <(fswatch -r --include '\.metadata\.json$' --exclude '.*' "$BRAIN_DIR")
elif [ "$WATCHER" = "inotifywait" ]; then
  while read -r changed_file; do
    [[ "$changed_file" == *.metadata.json ]] || continue
    handle_metadata_change "$changed_file"
  done < <(inotifywait -m -r -e modify,create --format '%w%f' "$BRAIN_DIR" 2>/dev/null)
fi
