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

# 10) Start Kismet and enforce WebUI user creation (pause + verify)
info "Step 10 — Start Kismet and ensure WebUI user exists"
sudo systemctl enable --now kismet.service || true
sudo systemctl restart kismet.service || true

KISMET_UI_HOST="127.0.0.1"
KISMET_UI_PORT="2501"
KISMET_UI="http://${KISMET_UI_HOST}:${KISMET_UI_PORT}"

log "Waiting for Kismet Web UI on ${KISMET_UI} ..."
ui_up=false
for i in {1..90}; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "${KISMET_UI}/index.html" || true)
  if [[ "$code" == "200" || "$code" == "302" || "$code" == "401" ]]; then
    log "Kismet WebUI responded with HTTP $code"
    ui_up=true
    break
  fi
  sleep 1
done
if ! $ui_up; then
  err "Web UI didn’t respond with 200/302/401 within 90s."
  systemctl --no-pager -l status kismet || true
  journalctl -u kismet -n 60 --no-pager -l | egrep -i 'http|home|web|listen|ui|error|fatal' || true
  log "You can still try opening: ${KISMET_UI}"
fi

HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -z "${HOST_IP:-}" ]] && HOST_IP="127.0.0.1"

cat <<HINT
Kismet requires an initial admin user created via the Web UI.

Open the Web UI in a browser and create the admin username & password:

  * Local GUI machine:
      ${KISMET_UI}

  * Another machine on LAN:
      http://${HOST_IP}:${KISMET_UI_PORT}

  * SSH headless server (from workstation):
      ssh -L ${KISMET_UI_PORT}:localhost:${KISMET_UI_PORT} ${USER}@${HOSTNAME:-host}
      Then open: http://localhost:${KISMET_UI_PORT}

After creating the account, you can either paste an API key (recommended)
or use the username/password you just created.
HINT

read -r -p "Press Enter once you've created the Kismet admin user in the Web UI..." _

# --- login helpers ---
attempt_kismet_api_variants() {
  local key="$1"; local ui="$2"; local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "${ui}/system/status.json?kismet=${key}" || echo "000")
  log "API check (?kismet=) returned HTTP $code"; [[ "$code" == "200" ]] && return 0
  code=$(curl -s -o /dev/null -w "%{http_code}" -H "Kismet-Api-Key: ${key}" "${ui}/system/status.json" || echo "000")
  log "API check (Kismet-Api-Key:) returned HTTP $code"; [[ "$code" == "200" ]] && return 0
  code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${key}" "${ui}/system/status.json" || echo "000")
  log "API check (Authorization: Bearer) returned HTTP $code"; [[ "$code" == "200" ]] && return 0
  if [[ "${key}" == kismet=* ]]; then
    local stripped="${key#kismet=}"
    code=$(curl -s -o /dev/null -w "%{http_code}" "${ui}/system/status.json?kismet=${stripped}" || echo "000")
    log "API check (stripped kismet=) returned HTTP $code"; [[ "$code" == "200" ]] && return 0
  fi
  return 1
}

attempt_kismet_password_cookie() {
  local user="$1" pass="$2" ui="$3" cookiefile="$4"
  rm -f "$cookiefile" 2>/dev/null || true
  code=$(curl -sS -c "$cookiefile" -u "$user:$pass" -o /dev/null -w "%{http_code}" "${ui}/system/status.json" || echo "000")
  [[ "$code" == "200" ]] && return 0
  code=$(curl -sS -c "$cookiefile" -X POST -H "Content-Type: application/json" \
              -d "{\"user\":\"$user\",\"password\":\"$pass\"}" \
              -o /dev/null -w "%{http_code}" "${ui}/session/login" || echo "000")
  [[ "$code" == "200" ]] || return 1
  code=$(curl -sS -b "$cookiefile" -o /dev/null -w "%{http_code}" "${ui}/system/status.json" || echo "000")
  [[ "$code" == "200" ]]
}
# --- end helpers ---

API_KEY_FILE="$ROOT/secure_credentials/kismet_api.key"
mkdir -p "$ROOT/secure_credentials"
chmod 700 "$ROOT/secure_credentials"

echo
read -r -p "Paste Kismet API key (recommended; leave blank to try user/pass instead): " API_KEY_INPUT

if [[ -n "${API_KEY_INPUT:-}" ]]; then
  if attempt_kismet_api_variants "${API_KEY_INPUT}" "${KISMET_UI}"; then
    printf "%s\n" "${API_KEY_INPUT}" > "${API_KEY_FILE}"
    chmod 600 "${API_KEY_FILE}"
    log "API key validated and saved to ${API_KEY_FILE}"
  else
    err "API key validation failed for common variants; falling back to user/password."
    API_KEY_INPUT=""
  fi
fi

if [[ -z "${API_KEY_INPUT}" ]]; then
  read -r -p "Kismet admin username: " KUSER
  read -r -s -p "Kismet admin password: " KPASS; echo
  COOKIE_FILE="$ROOT/secure_credentials/.kismet.cookies"
  if attempt_kismet_password_cookie "$KUSER" "$KPASS" "$KISMET_UI" "$COOKIE_FILE"; then
    log "Kismet password login verified for user '$KUSER'"
    printf "kismet_user=%s\nverified_at=%s\n" "$KUSER" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      > "$ROOT/secure_credentials/kismet_web_user.txt"
    chmod 600 "$ROOT/secure_credentials/kismet_web_user.txt"
  else
    err "Login failed with user/password. Consider using the API key (paste the raw key or the 'kismet=<key>' variant)."
    exit 1
  fi
fi

# 11) GUI env helper (project-local at $ROOT/etc_cyt/env)
info "Step 11 — GUI env helper (project-local)"
ENV_FILE="$ROOT/etc_cyt/env"
mkdir -p "$(dirname "$ENV_FILE")"
if [[ ! -f "$ENV_FILE" ]]; then
  cat > "$ENV_FILE" <<ENV
# CYT GUI env (created by bootstrap; project-local)
export DISPLAY=':0'
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
ENV
  chmod 600 "$ENV_FILE"
  log "Created GUI env file: $ENV_FILE"
else
  log "GUI env file already exists: $ENV_FILE"
fi

# Ensure start_gui.sh sources the project-local env
if [[ -f "$ROOT/start_gui.sh" ]]; then
  if ! grep -qE '\. "\$ROOT/etc_cyt/env"|\. "\$HOME/.config/cyt/env"|\. "\$ROOT/etc_cyt/env"$' "$ROOT/start_gui.sh"; then
    sed -i '1i ROOT="$(cd "$(dirname "$0")" && pwd)"; . "$ROOT/etc_cyt/env" || true' "$ROOT/start_gui.sh"
    chmod +x "$ROOT/start_gui.sh"
    log "Patched start_gui.sh to source $ROOT/etc_cyt/env"
  else
    log "start_gui.sh already sources an env file"
  fi
else
  warn "start_gui.sh not found in $ROOT; skipping env sourcing patch."
fi

# 12) Autostart entry + Desktop launcher (already installed from templates)
info "Step 12 — Autostart entry + Desktop launcher"
# (Installed in Step 4b from project templates)

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
