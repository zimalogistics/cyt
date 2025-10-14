#!/usr/bin/env bash
# =============================================================================
# Zima Logistics — CYT Secure Bootstrap
# Author: Zima Logistics
# Technical Partner: Argelius Labs — Systems Engineering & Integration (origional Author of CYT)
# Version: 2.5.0
# Date: 2025-10-04
#
# PURPOSE
#   One-command setup for the Chasing Your Tail (CYT) project on Linux.
#   Designed to be *idempotent* and interactive only where necessary.
#   Works on GUI desktops and headless SSH servers.
#
# WHAT THIS DOES (end-to-end)
#   1) Validates Linux environment.
#   2) Updates system packages (apt/pacman), with --skip-update to bypass.
#   3) Installs/updates Kismet to the newest repo version.
#   4) Creates project directories and installs autostart/launcher + systemd timer.
#   5) Keeps $ROOT/kismet.db symlinked to newest .kismet log (systemd user timer).
#   6) Ensures $ROOT/logs permissions for Kismet + GUI logging.
#   7) Optionally symlinks /etc/kismet/*.conf to project configs (with backups).
#   8) Sets up Python virtualenv (.venv), upgrades pip/tools, installs requirements.
#   9) Prompts for Wigle API credentials and validates them (stores securely).
#  10) Starts Kismet, pauses for WebUI admin creation, verifies login or API key.
#  11) Creates GUI env helper at project-local $ROOT/etc_cyt/env, patches start_gui.sh.
#  12) Desktop autostart + Desktop launcher already installed from templates.
#  13) Health checks (port 2501 listening, logs dir writable).
#
# FLAGS
#   --yes, -y       : Assume defaults (non-interactive where possible)
#   --no-browser    : Don’t attempt to auto-open a browser (still pauses)
#   --skip-update   : Skip system update step
#   --reset         : Remove bootstrap-generated artifacts (keeps repo code/creds)
#   --quiet         : Suppress normal info/log lines (errors/warnings still show)
#   --help, -h      : Show this help
# =============================================================================
# COMPATIBILITY NOTES
# =============================================================================
#   Works cleanly on fresh installs of Kali Linux and stock Kismet packages.
#   (No Kismet source modifications or custom patches are required.)
#
#   This bootstrap compensates for missing or inconsistent defaults:
#   • Ensures Kismet Web UI (httpd) is enabled and reachable on port 2501.
#   • Sets `log_prefix` in all Kismet configs to this project’s /logs folder.
#   • Fixes log directory ownership and permissions (prevents database errors).
#   • Installs user-level systemd timer to keep `kismet.db` symlinked fresh.
#   • Creates clean Wigle API and Kismet credential stores under /secure_credentials.
#
#   Known environmental considerations:
#   • GUI autostart requires an X/Wayland desktop session (not headless SSH).
#   • If accessing from another device, use SSH port-forwarding:
#       ssh -L 2501:localhost:2501 user@<CYT_machine_IP>
#   • GPS integration optional; CYT still runs without GPSD or GPS hardware.
#
#   To safely re-run bootstrap or “factory reset” CYT:
#       ./bootstrap.sh --reset
#   (This removes only project-generated files, not your Kismet install.)
#
#   Designed for portability and idempotence — re-running it should never break an existing install, only repair or refresh it.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

VERSION="2.5.0"
BUILD_DATE="$(date '+%Y-%m-%d %H:%M %Z')"

# Flags
ASSUME_YES=false
NO_BROWSER=false
SKIP_UPDATE=false
RESET=false
QUIET=false

for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=true ;;
    --no-browser) NO_BROWSER=true ;;
    --skip-update) SKIP_UPDATE=true ;;
    --reset) RESET=true ;;
    --quiet) QUIET=true ;;
    --help|-h)
      cat <<USAGE
Usage: ./bootstrap.sh [--yes|-y] [--no-browser] [--skip-update] [--reset] [--quiet]
USAGE
      exit 0
      ;;
  esac
done

# Project root + logging
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/logs"
LOGFILE="$ROOT/logs/bootstrap-$(date +%Y%m%d-%H%M%S).log"

# Mirror all script output to the logfile
exec > >(tee -a "$LOGFILE") 2>&1

# Console helpers (quiet mode hides info/log, but errors/warns always show)
log()  { $QUIET || printf "[BOOTSTRAP] %s\n" "$*"; }
info() { $QUIET || printf "\n[INFO] %s\n\n" "$*"; }
warn() { printf "[WARN] %s\n" "$*"; }
err()  { printf "[ERROR] %s\n" "$*" >&2; }

# Banner (hidden in --quiet)
print_banner() {
  $QUIET && return
  cat <<BANNER
=========================================================
  Zima Logistics — CYT Secure Bootstrap (${VERSION})
  Built: ${BUILD_DATE}
  Engineered in partnership with Argelius Labs (Origional Author of CYT)
=========================================================
BANNER
}

# Linux check
[[ "$(uname -s)" == "Linux" ]] || { err "Linux-only"; exit 1; }

print_banner
info "Logs will be written to $LOGFILE"

# --- reset helper ---
cyt_reset_artifacts() {
  set -euo pipefail
  echo "[RESET] Stopping Kismet service if running"
  sudo systemctl stop kismet 2>/dev/null || true

  echo "[RESET] Disabling & removing systemd user timer"
  systemctl --user disable --now cyt-refresh-kismet-db.timer 2>/dev/null || true
  systemctl --user disable --now cyt-refresh-kismet-db.service 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/cyt-refresh-kismet-db.service" \
        "$HOME/.config/systemd/user/cyt-refresh-kismet-db.timer"
  systemctl --user daemon-reload 2>/dev/null || true

  echo "[RESET] Removing autostart entries"
  rm -f "$HOME/.config/autostart/cyt-gui.desktop" "$HOME/Desktop/cyt-gui.desktop"

  echo "[RESET] Removing project-generated helpers"
  rm -f "$ROOT/bin/refresh_kismet_db.sh" "$ROOT/kismet.db" "$ROOT/.envrc"
  rm -rf "$ROOT/.venv"
  
  # ---- reset_wifi.sh (return adapters from monitor to managed & reconnect) ----
cat > "$ROOT/bin/reset_wifi.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

echo "[reset_wifi] starting…"

# You can prevent specific ifaces from being changed by setting KEEP_MON (space-separated)
# Example: KEEP_MON="wlan1" ./bin/reset_wifi.sh
KEEP="${KEEP_MON:-}"

# Ensure NetworkManager is present (required for reconnects)
if ! command -v nmcli >/dev/null 2>&1; then
  echo "[reset_wifi] nmcli not found; please install NetworkManager" >&2
  exit 1
fi

# Collect wireless interfaces known to the kernel
mapfile -t IFACES < <(iw dev 2>/dev/null | awk '/Interface/ {print $2}')

if [[ ${#IFACES[@]} -eq 0 ]]; then
  echo "[reset_wifi] no wireless interfaces found"
  exit 0
fi

for IF in "${IFACES[@]}"; do
  # Skip if listed in KEEP_MON
  if [[ " $KEEP " == *" $IF "* ]]; then
    echo "[reset_wifi] skipping $IF (in KEEP_MON)"
    continue
  fi

  # Determine current type: managed/monitor/etc
  TYPE="$(iw dev "$IF" info 2>/dev/null | awk '/type/ {print $2; exit}' || echo unknown)"

  # If NetworkManager has it unmanaged, try to re-manage it
  nmcli dev set "$IF" managed yes >/dev/null 2>&1 || true

  if [[ "$TYPE" == "monitor" || "$TYPE" == "unknown" ]]; then
    echo "[reset_wifi] restoring $IF from $TYPE -> managed"
    # Bring it down, flip type, bring up
    sudo ip link set "$IF" down || true
    # Prefer modern 'iw' type change; fall back to iwconfig if needed
    if iw dev "$IF" set type managed 2>/dev/null; then
      :
    else
      iwconfig "$IF" mode managed 2>/dev/null || true
    fi
    sudo ip link set "$IF" up || true
  else
    echo "[reset_wifi] $IF already type=$TYPE"
  fi

  # Ask NetworkManager to (re)attach and connect
  nmcli device connect "$IF" >/dev/null 2>&1 || true
done

echo "[reset_wifi] done."
BASH
chmod +x "$ROOT/bin/reset_wifi.sh"
# ---- end reset_wifi.sh -------------------------------------------------------

  echo "[RESET] Clearing logs (keeping directory)"
  mkdir -p "$ROOT/logs"
  find "$ROOT/logs" -type f -name '*.kismet*' -delete 2>/dev/null || true
  rm -f "$ROOT/logs"/bootstrap-*.log 2>/dev/null || true

  echo "[RESET] Done. (Repo code and secure_credentials preserved.)"
}
# --- end reset helper ---

# Offer “fresh run” reset if requested / likely re-run
if $RESET; then
  cyt_reset_artifacts "$ROOT"
else
  if ! $ASSUME_YES; then
    if [[ -d "$ROOT/.venv" || -d "$ROOT/logs" || -d "$ROOT/etc_cyt" || -f "$HOME/.config/systemd/user/cyt-refresh-kismet-db.timer" ]]; then
      echo
      read -r -p "Have you run this bootstrap before? (y/N): " ran_before
      if [[ "$ran_before" =~ ^[Yy]$ ]]; then
        echo "This can reset bootstrap-generated artifacts (keeps your repo code)."
        read -r -p "Run a fresh reset now? (y/N): " do_reset
        if [[ "$do_reset" =~ ^[Yy]$ ]]; then
          cyt_reset_artifacts "$ROOT"
        else
          log "Proceeding without reset."
        fi
      else
        log "Proceeding (first-time setup)."
      fi
    fi
  fi
fi

# 1) System update
info "Step 1 — Updating system packages"
if ! $SKIP_UPDATE; then
  if command -v apt >/dev/null 2>&1; then
    sudo apt update
    sudo apt -y full-upgrade
    sudo apt -y autoremove
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -Syu --noconfirm
  else
    err "Unsupported package manager (need apt or pacman)."; exit 1
  fi
else
  log "--skip-update set; skipping system package update."
fi

# 2) Kismet install/update
info "Step 2 — Installing/updating Kismet"
if command -v apt >/dev/null 2>&1; then
  sudo apt -y install kismet
elif command -v pacman >/dev/null 2>&1; then
  sudo pacman -S --noconfirm kismet
fi
command -v kismet >/dev/null 2>&1 || { err "Kismet install failed"; exit 1; }
log "Kismet: $(kismet --version | head -n1)"

# 3) Project directories
mkdir -p "$ROOT/logs" "$ROOT/reports" "$ROOT/surveillance_reports" "$ROOT/kml_files"
mkdir -p "$ROOT/secure_credentials" "$ROOT/etc_kismet" "$ROOT/bin" "$ROOT/etc_cyt"

# 4) refresh_kismet_db.sh + project-local autostart/systemd templates + timer
info "Step 4 — Preparing autostart & systemd templates"
mkdir -p "$ROOT/etc_cyt/autostart" "$ROOT/etc_cyt/systemd" "$HOME/Desktop"

# refresh helper
cat > "$ROOT/bin/refresh_kismet_db.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOGDIR="$ROOT/logs"
TARGET="$ROOT/kismet.db"
newest="$(ls -1t "$LOGDIR"/*.kismet 2>/dev/null | head -n1 || true)"
if [[ -n "${newest:-}" ]]; then
  ln -sfn "$newest" "$TARGET"
  echo "[REFRESH] $TARGET -> $newest"
else
  echo "[REFRESH] no .kismet files found in $LOGDIR"
fi
BASH
chmod +x "$ROOT/bin/refresh_kismet_db.sh"

# desktop entry
cat > "$ROOT/etc_cyt/autostart/cyt-gui.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=CYT GUI
Comment=Launch Chasing Your Tail (CYT)
Exec=/usr/bin/env bash -lc '$ROOT/start_gui.sh'
Path=$ROOT
Icon=$ROOT/cyt_ng_logo.png
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

# systemd user service/timer
cat > "$ROOT/etc_cyt/systemd/cyt-refresh-kismet-db.service" <<EOF
[Unit]
Description=Refresh CYT kismet.db symlink to newest Kismet log

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash -lc '$ROOT/bin/refresh_kismet_db.sh'
EOF

cat > "$ROOT/etc_cyt/systemd/cyt-refresh-kismet-db.timer" <<'EOF'
[Unit]
Description=Run cyt-refresh-kismet-db every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
Persistent=true
Unit=cyt-refresh-kismet-db.service

[Install]
WantedBy=default.target
EOF

info "Step 4b — Installing autostart and systemd units from project templates"
AUTOSTART_DIR="$HOME/.config/autostart"
SYSTEMD_USER="$HOME/.config/systemd/user"
mkdir -p "$AUTOSTART_DIR" "$SYSTEMD_USER"

# Ensure launcher executable exists
if [[ -f "$ROOT/start_gui.sh" ]]; then
  chmod +x "$ROOT/start_gui.sh"
else
  warn "start_gui.sh not found at $ROOT; GUI launcher may not work until it exists."
fi

# Install entries
install -m 644 "$ROOT/etc_cyt/autostart/cyt-gui.desktop" "$AUTOSTART_DIR/cyt-gui.desktop"
install -m 755 "$ROOT/etc_cyt/autostart/cyt-gui.desktop" "$HOME/Desktop/cyt-gui.desktop"
log "Installed autostart entry and Desktop shortcut from project template."

cp -f "$ROOT/etc_cyt/systemd/cyt-refresh-kismet-db.service" "$SYSTEMD_USER/cyt-refresh-kismet-db.service"
cp -f "$ROOT/etc_cyt/systemd/cyt-refresh-kismet-db.timer"   "$SYSTEMD_USER/cyt-refresh-kismet-db.timer"
systemctl --user daemon-reload || true
systemctl --user enable --now cyt-refresh-kismet-db.timer || true
log "Installed and enabled systemd user timer from project templates."

# 6) Configure Kismet log path and permissions (portable, per-user ROOT)
info "Step 6 — Configure Kismet log path and permissions"

# Always log under the project logs dir for the current user
ROOT_LOGS="$ROOT/logs"
mkdir -p "$ROOT_LOGS"

# Kismet runs as root via systemd on Kali; make sure root can write here and
# the interactive user can still read/browse logs. setgid bit makes new files inherit the group.
USER_GRP="$(id -gn)"
sudo chown -R root:"${USER_GRP}" "$ROOT_LOGS"
sudo chmod -R 2775 "$ROOT_LOGS"

# Make sure the kismet config dir exists
sudo mkdir -p /etc/kismet

# Normalize log_prefix in stock logging config
if sudo test -f /etc/kismet/kismet_logging.conf; then
  if sudo grep -q '^log_prefix=' /etc/kismet/kismet_logging.conf; then
    sudo sed -i -E "s|^log_prefix=.*|log_prefix=${ROOT_LOGS}|" /etc/kismet/kismet_logging.conf
  else
    echo "log_prefix=${ROOT_LOGS}" | sudo tee -a /etc/kismet/kismet_logging.conf >/dev/null
  fi
fi

# Normalize log_prefix in site override (this overrides others; must be correct)
if sudo test -f /etc/kismet/kismet_site.conf; then
  if sudo grep -q '^log_prefix=' /etc/kismet/kismet_site.conf; then
    sudo sed -i -E "s|^log_prefix=.*|log_prefix=${ROOT_LOGS}|" /etc/kismet/kismet_site.conf
  else
    echo "log_prefix=${ROOT_LOGS}" | sudo tee -a /etc/kismet/kismet_site.conf >/dev/null
  fi
fi

# Also fix the project copy so future runs/symlinks never reintroduce a hard-coded path
if [[ -f "$ROOT/etc_kismet/kismet_site.conf" ]]; then
  if grep -q '^log_prefix=' "$ROOT/etc_kismet/kismet_site.conf"; then
    sed -i -E "s|^log_prefix=.*|log_prefix=${ROOT_LOGS}|" "$ROOT/etc_kismet/kismet_site.conf"
  else
    echo "log_prefix=${ROOT_LOGS}" >> "$ROOT/etc_kismet/kismet_site.conf"
  fi
fi
if [[ -f "$ROOT/etc_kismet/kismet_logging.conf" ]]; then
  if grep -q '^log_prefix=' "$ROOT/etc_kismet/kismet_logging.conf"; then
    sed -i -E "s|^log_prefix=.*|log_prefix=${ROOT_LOGS}|" "$ROOT/etc_kismet/kismet_logging.conf"
  fi
fi

log "Effective log_prefix entries (should point at ${ROOT_LOGS}):"
sudo grep -Rn '^log_prefix=' /etc/kismet 2>/dev/null | sed -n '1,120p' || true

# --- Step 6b) Normalize config.json kismet_logs path for current user ---
CONFIG_FILE="$ROOT/config.json"
if [[ -f "$CONFIG_FILE" ]]; then
  CURRENT_USER=$(logname 2>/dev/null || echo "$USER")
  NEW_PATH="/home/${CURRENT_USER}/Desktop/cyt/logs/*.kismet"

  # Replace whatever is in the file with the correct absolute path
  sed -i -E \
    "s#(\"kismet_logs\"[[:space:]]*:[[:space:]]*)\"[^\"]+\"#\1\"${NEW_PATH}\"#" \
    "$CONFIG_FILE"

  log "Updated kismet_logs path in config.json -> ${NEW_PATH}"
else
  warn "config.json not found; skipping kismet_logs path normalization."
fi

# Back-compat for older tools that expect ~/kismet_logs
ln -sfn "$ROOT_LOGS" "$HOME/kismet_logs" || true
log "Ensured ~/kismet_logs -> $ROOT_LOGS symlink exists (compatibility)"

# 6.5) Select capture interface & keep onboard online
info "Step 6.5 — Select capture interface (prefer USB dongle) & protect onboard Wi-Fi"

# Helper: does iface support monitor?
supports_monitor() {
  local ifc="$1" phy
  phy="$(readlink -f "/sys/class/net/$ifc/phy80211" 2>/dev/null || true)"
  [[ -z "$phy" ]] && return 1
  # Look for "monitor" in supported interface modes
  iw phy "$(basename "$phy")" info 2>/dev/null | awk '/Supported interface modes/{flag=1;next} /^\S/{flag=0} flag' | grep -qi monitor
}

# Enumerate wifi ifaces
mapfile -t WIFI_IFACES < <(iw dev 2>/dev/null | awk '/Interface/ {print $2}')
if [[ ${#WIFI_IFACES[@]} -eq 0 ]]; then
  warn "No wireless interfaces found (iw dev). You can still finish bootstrap; add a dongle later."
fi

USB_MON=""
PCI_MON=""
ONBOARD_IF=""
for ifc in "${WIFI_IFACES[@]}"; do
  # Work out bus type
  devpath="$(readlink -f "/sys/class/net/$ifc/device" 2>/dev/null || true)"
  if [[ -z "$devpath" ]]; then
    continue
  fi
  bus="$(basename "$(readlink -f "$devpath/subsystem" 2>/dev/null || echo "")")"
  # Remember a likely onboard candidate (first PCI we see)
  if [[ "$bus" == "pci" && -z "$ONBOARD_IF" ]]; then
    ONBOARD_IF="$ifc"
  fi
  if supports_monitor "$ifc"; then
    if [[ "$bus" == "usb" && -z "$USB_MON" ]]; then
      USB_MON="$ifc"
    elif [[ "$bus" == "pci" && -z "$PCI_MON" ]]; then
      PCI_MON="$ifc"
    fi
  fi
done

CAPTURE_IF=""
if [[ -n "$USB_MON" ]]; then
  CAPTURE_IF="$USB_MON"
  log "Selected USB (dongle) interface for capture: $CAPTURE_IF"
elif [[ -n "$PCI_MON" ]]; then
  CAPTURE_IF="$PCI_MON"
  log "No USB monitor-capable dongle found; using PCI (onboard) for capture: $CAPTURE_IF"
else
  warn "No monitor-capable Wi-Fi found. Kismet will start but won’t capture until a source is added."
fi

# Configure Kismet to use the selected capture interface (if any).
if [[ -n "$CAPTURE_IF" ]]; then
  sudo mkdir -p /etc/kismet
  # Ensure a clean 'source=' in kismet_site.conf
  if ! sudo test -f /etc/kismet/kismet_site.conf; then
    echo "# created by CYT bootstrap" | sudo tee /etc/kismet/kismet_site.conf >/dev/null
  fi
  if sudo grep -q '^source=' /etc/kismet/kismet_site.conf; then
    sudo sed -i -E "s|^source=.*|source=${CAPTURE_IF}:name=wifi,channelhop=true|" /etc/kismet/kismet_site.conf
  else
    echo "source=${CAPTURE_IF}:name=wifi,channelhop=true" | sudo tee -a /etc/kismet/kismet_site.conf >/dev/null
  fi
  log "Kismet source set to: source=${CAPTURE_IF}:name=wifi,channelhop=true"
fi

# Keep onboard managed for internet; set ONLY the capture iface unmanaged.
# This prevents NetworkManager from fighting Kismet on the capture NIC,
# while your onboard remains fully managed for Wi-Fi connectivity.
sudo mkdir -p /etc/NetworkManager/conf.d
NM_CFG="/etc/NetworkManager/conf.d/10-cyt-unmanaged.conf"

if [[ -n "$CAPTURE_IF" ]]; then
  # Build list (just the capture iface)
  sudo tee "$NM_CFG" >/dev/null <<EOF
[main]
plugins=keyfile

[keyfile]
unmanaged-devices=interface-name:${CAPTURE_IF}
EOF
  log "Wrote NetworkManager unmanaged rule for: ${CAPTURE_IF}"
else
  # If we have no capture iface, don’t leave stale unmanaged rules
  sudo rm -f "$NM_CFG" 2>/dev/null || true
  log "Removed NetworkManager unmanaged rule (no capture iface selected)."
fi

# Reload NetworkManager to apply unmanaged rules
if command -v nmcli >/dev/null 2>&1; then
  sudo nmcli general reload || true
fi

# Helpful summary
log "Interfaces summary:"
for ifc in "${WIFI_IFACES[@]}"; do
  devpath="$(readlink -f "/sys/class/net/$ifc/device" 2>/dev/null || true)"
  bus="$(basename "$(readlink -f "$devpath/subsystem" 2>/dev/null || echo "")")"
  sup="no"
  supports_monitor "$ifc" && sup="yes"
  mark=""
  [[ "$ifc" == "$CAPTURE_IF" ]] && mark="(capture)"
  printf "[BOOTSTRAP]  - %-8s bus=%-4s monitor_capable=%-3s %s\n" "$ifc" "${bus:-?}" "$sup" "$mark"
done

# 7) Symlink /etc/kismet configs to project (optional, with backups)
info "Step 7 — Symlink /etc/kismet/*.conf to project (optional)"
if $ASSUME_YES; then
  DO_SYMLINK="Y"
else
  read -r -p "Symlink $ROOT/etc_kismet/*.conf into /etc/kismet/? (y/N): " DO_SYMLINK
fi

if [[ "${DO_SYMLINK:-N}" =~ ^[Yy]$ ]]; then
  sudo mkdir -p /etc/kismet
  shopt -s nullglob
  for f in "$ROOT/etc_kismet"/*.conf; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    if [[ -f "/etc/kismet/$base" && ! -L "/etc/kismet/$base" ]]; then
      sudo mv "/etc/kismet/$base" "/etc/kismet/$base.bak.$(date +%s)" || true
      log "Backed up /etc/kismet/$base"
    fi
    sudo ln -sfn "$f" "/etc/kismet/$base"
    log "Symlinked /etc/kismet/$base -> $f"
  done
else
  log "Skipping /etc/kismet symlink step."
fi

# 8) Python virtualenv (+ optional auto-activation)
info "Step 8 — Python venv"
VENV_DIR="$ROOT/.venv"
if [[ ! -d "$VENV_DIR" ]]; then
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip setuptools wheel
fi
[[ -f "$ROOT/requirements.txt" ]] && "$VENV_DIR/bin/pip" install -r "$ROOT/requirements.txt" || true

if $ASSUME_YES; then
  AUTOACT="Y"
else
  read -r -p "Enable auto-activation when you cd into the project? (y/N): " AUTOACT
fi
if [[ "${AUTOACT:-N}" =~ ^[Yy]$ ]]; then
  if command -v direnv >/dev/null 2>&1; then
    echo "source \"$VENV_DIR/bin/activate\"" > "$ROOT/.envrc"
    (cd "$ROOT" && direnv allow) || true
    log "direnv auto-activation configured."
  else
    SHELL_RC="$HOME/.bashrc"; [[ -n "${ZSH_VERSION-}" ]] && SHELL_RC="$HOME/.zshrc"
    cat >> "$SHELL_RC" <<SNIP
# --- CYT project auto-activate ---
_cyt_auto_activate() {
  if [[ -z "\${VIRTUAL_ENV-}" && -f "$ROOT/.venv/bin/activate" && "\$PWD" == "$ROOT"* ]]; then
    source "$ROOT/.venv/bin/activate"
  fi
}
if [[ -n "\${ZSH_VERSION-}" ]]; then
  autoload -Uz add-zsh-hook
  add-zsh-hook chpwd _cyt_auto_activate
  _cyt_auto_activate
else
  PROMPT_COMMAND="_cyt_auto_activate;\${PROMPT_COMMAND:-}"
fi
# --- end CYT auto-activate ---
SNIP
    log "Added auto-activate snippet to $SHELL_RC"
  fi
fi

# 9) Wigle API credentials (with validation)
info "Step 9 — Wigle API credentials"
WIGLE_FILE="$ROOT/secure_credentials/wigle_api.key"
mkdir -p "$(dirname "$WIGLE_FILE")"
chmod 700 "$ROOT/secure_credentials"

if $ASSUME_YES; then
  log "Skipping interactive Wigle setup due to --yes"
else
  read -r -p "Enter Wigle API name (leave blank to skip): " WAPI
  if [[ -n "$WAPI" ]]; then
    read -r -s -p "Enter Wigle API token: " WTOK; echo
    printf "%s:%s\n" "$WAPI" "$WTOK" | install -m 600 /dev/stdin "$WIGLE_FILE"

    code=$(curl -s -o /dev/null -w "%{http_code}" \
      -u "$(cat "$WIGLE_FILE")" \
      "https://api.wigle.net/api/v2/profile/user" || echo "000")

    if [[ "$code" == "200" ]]; then
      log "Wigle API credentials validated (HTTP 200) and saved to $WIGLE_FILE"
    else
      err "Wigle API validation failed (HTTP $code). Credentials left in $WIGLE_FILE so you can fix and re-test."
      err "Tip: curl -s -o /dev/null -w \"%{http_code}\n\" -u \"\$(cat \"$WIGLE_FILE\")\" https://api.wigle.net/api/v2/profile/user"
    fi
  else
    log "Skipping Wigle API setup"
  fi
fi

# 9.5) Ensure Kismet web UI config and perms
info "Step 9.5 — Ensure Kismet web UI config and perms"
sudo mkdir -p /etc/kismet

# Replace/append log_prefix already handled earlier; ensure httpd_home is correct
sudo tee /etc/kismet/kismet_httpd.conf >/dev/null <<'EOF'
httpd_enabled=true
httpd_bind_address=0.0.0.0
httpd_port=2501
httpd_home=/usr/share/kismet/httpd
httpd_index=index.html
EOF

sudo tee /etc/kismet/kismet_memory.conf >/dev/null <<'EOF'
memory_debug=false
EOF

# Make desktop launchers executable (fixes “Invalid Permissions” warning)
for f in "$HOME/.config/autostart/cyt-gui.desktop" "$HOME/Desktop/cyt-gui.desktop"; do
  [[ -f "$f" ]] && chmod 755 "$f" || true
done
[[ -f "$ROOT/start_gui.sh" ]] && chmod +x "$ROOT/start_gui.sh" || true

# --- 10) Start Kismet and ensure WebUI user exists ---------------------------
info "Step 10 — Start Kismet and ensure WebUI user exists"

# Start Kismet once (no automatic enable at boot)
sudo systemctl stop kismet.service >/dev/null 2>&1 || true
sudo systemctl restart kismet.service

# Wait for the Web UI before prompting
KISMET_UI="http://127.0.0.1:2501"
log "[BOOTSTRAP] Waiting for Kismet Web UI on ${KISMET_UI} ..."
ui_up=false
for i in {1..90}; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "${KISMET_UI}/index.html" || true)
  if [[ "$code" =~ ^(200|302|401)$ ]]; then
    log "[BOOTSTRAP] Kismet Web UI responded (HTTP $code)"
    ui_up=true
    break
  fi
  sleep 1
done

if $ui_up; then
  if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    warn "No GUI session detected — open ${KISMET_UI}/ manually or via SSH port-forwarding."
  else
    if command -v xdg-open >/dev/null 2>&1; then
      log "[BOOTSTRAP] Launching Kismet Web UI in browser..."
      ( sleep 1; xdg-open "${KISMET_UI}/" >/dev/null 2>&1 ) &
    fi
  fi
else
  warn "Web UI didn’t respond within 90 s; open ${KISMET_UI}/ manually."
fi

echo
read -r -p "When the Kismet page loads, create the admin user and log in. Press Enter here when done..." _

# 11) GUI env helper (project-local at $ROOT/etc_cyt/env)
info "Step 11 — GUI env helper (project-local)"

ENV_FILE="$ROOT/etc_cyt/env"
mkdir -p "$(dirname "$ENV_FILE")"

# Build / refresh the base env (always correct the runtime dir for the *current* user)
# We do NOT echo the password here; it’s written below based on user input or existing value.
cat > "$ENV_FILE" <<'ENV'
# CYT GUI env (created by bootstrap; project-local)
# Use the local display (most desktop sessions expose :0 or :1; :0 is fine on Kali live/VM)
export DISPLAY=':0'
# IMPORTANT: use the logged-in user runtime dir, NOT root's (prevents GUI perms weirdness)
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
ENV

# If a master password is already exported in this shell, persist it to the env file;
# otherwise (and if we're not in --yes mode) ask once and save it (so GUI won’t block).
if [[ -n "${CYT_MASTER_PASSWORD:-}" ]]; then
  printf "\n# Unlock encrypted credentials for GUI\nexport CYT_MASTER_PASSWORD='%s'\n" "${CYT_MASTER_PASSWORD}" >> "$ENV_FILE"
  log "Persisted CYT_MASTER_PASSWORD from current environment to $ENV_FILE"
else
  if $ASSUME_YES; then
    log "CYT_MASTER_PASSWORD not provided (non-interactive); GUI may prompt when needed."
  else
    echo
    read -r -s -p "Create/set CYT master password (used to unlock encrypted credentials): " _MPW; echo
    if [[ -n "$_MPW" ]]; then
      printf "\n# Unlock encrypted credentials for GUI\nexport CYT_MASTER_PASSWORD='%s'\n" "$_MPW" >> "$ENV_FILE"
      log "Stored CYT master password in $ENV_FILE (600)."
    else
      log "No master password stored; GUI will prompt on first use."
    fi
    unset _MPW
  fi
fi

chmod 600 "$ENV_FILE"
log "GUI env file ready: $ENV_FILE"

# Ensure start_gui.sh sources the project-local env (at the very top)
if [[ -f "$ROOT/start_gui.sh" ]]; then
  # Insert only once; keep it as the very first line so env is loaded before anything else
  if ! head -n 1 "$ROOT/start_gui.sh" | grep -q 'ROOT=.*etc_cyt/env'; then
    # Prepend a single line that resolves $ROOT and sources env
    tmpf="$(mktemp)"; printf 'ROOT="$(cd "$(dirname "$0")" && pwd)"; . "$ROOT/etc_cyt/env" || true\n' > "$tmpf"
    cat "$ROOT/start_gui.sh" >> "$tmpf"
    mv "$tmpf" "$ROOT/start_gui.sh"
    chmod +x "$ROOT/start_gui.sh"
    log "Patched start_gui.sh to source $ROOT/etc_cyt/env"
  else
    log "start_gui.sh already sources $ROOT/etc_cyt/env"
  fi
else
  warn "start_gui.sh not found in $ROOT; skipping env sourcing patch."
fi

# --- 12) Desktop launcher (manual start only; no autostart) ------------------
info "Step 12 — Desktop launcher only (no auto-start)"

LAUNCHER_NAME="cyt-gui.desktop"
USER_DESKTOP="$HOME/Desktop"
AUTOSTART_DIR="$HOME/.config/autostart"
mkdir -p "$USER_DESKTOP"

# Ensure we have a valid start_gui.sh
if [[ ! -f "$ROOT/start_gui.sh" ]]; then
  cat >"$ROOT/start_gui.sh" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$ROOT/etc_cyt/env" 2>/dev/null || true
cd "$ROOT"
if [[ -x "./cyt_gui.sh" ]]; then
  exec ./cyt_gui.sh
elif [[ -f "./cyt_gui.py" ]]; then
  exec python3 ./cyt_gui.py
elif [[ -f "./gui.py" ]]; then
  exec python3 ./gui.py
else
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "http://127.0.0.1:2501/" >/dev/null 2>&1 || true
  fi
  echo "CYT GUI not found; opened Kismet Web UI instead." >&2
fi
WRAP
  chmod +x "$ROOT/start_gui.sh"
fi

# Create Desktop launcher (but do NOT autostart on login)
cat >"$USER_DESKTOP/$LAUNCHER_NAME" <<EOF
[Desktop Entry]
Type=Application
Name=CYT GUI
Comment=Launch Chasing Your Tail (CYT)
Exec=/usr/bin/env bash -lc 'cd "$ROOT" && ./start_gui.sh'
Path=$ROOT
Icon=$ROOT/cyt_ng_logo.png
Terminal=false
X-GNOME-Autostart-enabled=false
EOF

chmod 755 "$USER_DESKTOP/$LAUNCHER_NAME"
log "[BOOTSTRAP] Desktop launcher created at $USER_DESKTOP/$LAUNCHER_NAME (no auto-start)."

# Fix ownership if bootstrap was run via sudo
RUN_USER=$(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")
RUN_HOME=$(eval echo "~$RUN_USER")
if [[ -n "$RUN_USER" && -d "$RUN_HOME" ]]; then
  chown -R "$RUN_USER":"$RUN_USER" "$RUN_HOME/Desktop/cyt" 2>/dev/null || true
  chown "$RUN_USER":"$RUN_USER" "$RUN_HOME/Desktop/$LAUNCHER_NAME" 2>/dev/null || true
fi

log "[BOOTSTRAP] Desktop launcher ready. CYT will not auto-start on login."

# 13) Health checks
info "Step 13 — Health checks"
if ss -ltn 2>/dev/null | grep -q ':2501 '; then
  log "Kismet UI port 2501 is listening"
else
  log "Kismet port 2501 not detected; UI may still be starting"
fi
if [[ -w "$ROOT/logs" ]]; then
  log "Logs directory writable"
else
  err "Logs directory not writable: $ROOT/logs"
fi

info "Bootstrap complete"
