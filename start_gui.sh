#!/usr/bin/env bash
set -euo pipefail

# Resolve project root
ROOT="$(cd "$(dirname "$0")" && pwd)"

# Load GUI env (contains CYT_MASTER_PASSWORD)
if [ -f "$ROOT/etc_cyt/env" ]; then
  # shellcheck source=/dev/null
  . "$ROOT/etc_cyt/env"
fi

# Minimal sanity logging (masked) so we can see what the GUI actually gets
LOG="$ROOT/gui_startup.log"
PW_MASK="unset"
if [ "${CYT_MASTER_PASSWORD-__missing__}" != "__missing__" ] && [ -n "${CYT_MASTER_PASSWORD}" ]; then
  PW_MASK="set,len=${#CYT_MASTER_PASSWORD}"
fi
{
  echo "$(date) start_gui.sh"
  echo "ROOT=$ROOT"
  echo "DISPLAY=${DISPLAY-<unset>}  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR-<unset>}"
  echo "CYT_MASTER_PASSWORD:$PW_MASK"
} >> "$LOG"

# Ensure we’re in the project directory
cd "$ROOT"

# Launch the GUI
exec python3 cyt_gui.py
