#!/usr/bin/env bash
set -euo pipefail

readonly LOG_PREFIX="[autodarts-setup]"
readonly AUTODARTS_INSTALL_URL="https://autodarts.sh/sh/install.sh"
readonly TAILSCALE_INSTALL_URL="https://tailscale.com/install.sh"

log() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }
warn() { printf '%s WARNING: %s\n' "$LOG_PREFIX" "$*" >&2; }
die() { printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; exit 1; }

# --- Configuration (override via environment) ---
BOARD_USER="${BOARD_USER:-pi}"
CUSTOMER="${CUSTOMER:-}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
INSTALL_UVC_HACK="${INSTALL_UVC_HACK:-0}"
AUTODARTS_BETA="${AUTODARTS_BETA:-0}"

if [[ -z "${TZ:-}" ]]; then
  TZ="Europe/Stockholm"
fi
export TZ

require_root() {
  if [[ "${EUID:-}" -ne 0 ]]; then
    die "Kör som root: curl ... | sudo bash   (eller sudo ./install.sh)"
  fi
}

require_pi_arm64() {
  local arch
  arch="$(uname -m)"
  if [[ "$arch" != "aarch64" && "$arch" != "arm64" ]]; then
    die "Stödjer endast 64-bit ARM (aarch64). Detekterat: ${arch}"
  fi
  if [[ ! -f /proc/device-tree/model ]]; then
    warn "Kunde inte läsa /proc/device-tree/model — fortsätter ändå (är detta en Raspberry Pi?)"
    return
  fi
  local model
  model="$(tr -d '\0' < /proc/device-tree/model)"
  if [[ "$model" != *"Raspberry Pi"* ]]; then
    warn "Enheten verkar inte vara en Raspberry Pi (${model}). Skriptet är avsett för Pi 4B."
  fi
}

require_board_user() {
  if ! id "$BOARD_USER" &>/dev/null; then
    die "Användaren '${BOARD_USER}' finns inte. Skapa den eller sätt BOARD_USER."
  fi
}

board_home() {
  getent passwd "$BOARD_USER" | cut -d: -f6
}

run_as_board_user() {
  local cmd=$1
  local home
  home="$(board_home)"
  sudo -u "$BOARD_USER" -H env HOME="$home" USER="$BOARD_USER" LOGNAME="$BOARD_USER" \
    bash -lc "$cmd"
}

apt_install_if_missing() {
  local pkgs=("$@")
  local missing=()
  local p
  for p in "${pkgs[@]}"; do
  if ! dpkg -s "$p" &>/dev/null; then
      missing+=("$p")
    fi
  done
  if ((${#missing[@]} > 0)); then
    log "Installerar paket: ${missing[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
  fi
}

configure_hostname() {
  if [[ -z "$CUSTOMER" ]]; then
    log "CUSTOMER ej satt — behåller nuvarande värdnamn ($(hostname))"
    return
  fi
  local new_host="autodarts-${CUSTOMER}"
  if [[ "$(hostname)" == "$new_host" ]]; then
    log "Värdnamn redan ${new_host}"
    return
  fi
  log "Sätter värdnamn till ${new_host}"
  hostnamectl set-hostname "$new_host"
  if grep -q "^127.0.1.1" /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1\t${new_host}/" /etc/hosts
  else
    echo -e "127.0.1.1\t${new_host}" >> /etc/hosts
  fi
}

configure_timezone() {
  local current
  current="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  if [[ "$current" == "$TZ" ]]; then
    log "Tidszon redan ${TZ}"
    return
  fi
  log "Sätter tidszon ${TZ}"
  timedatectl set-timezone "$TZ"
}

configure_unattended_upgrades() {
  apt_install_if_missing unattended-upgrades apt-listchanges
  if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
    log "unattended-upgrades redan konfigurerad"
  else
    log "Aktiverar unattended-upgrades (säkerhetsuppdateringar)"
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  fi
  systemctl enable unattended-upgrades.service 2>/dev/null || true
}

disable_unneeded_services() {
  local svc
  for svc in bluetooth.service avahi-daemon.service; do
    if systemctl list-unit-files "$svc" &>/dev/null; then
      if systemctl is-enabled "$svc" &>/dev/null; then
        log "Inaktiverar ${svc}"
        systemctl disable --now "$svc" 2>/dev/null || true
      fi
    fi
  done
}

install_tailscale() {
  if command -v tailscale &>/dev/null; then
    log "Tailscale redan installerat"
  else
    log "Installerar Tailscale (officiellt skript)"
    # shellcheck disable=SC1090
    bash -c "$(curl -fsSL "${TAILSCALE_INSTALL_URL}")"
  fi

  if tailscale set --help 2>/dev/null | grep -q auto-update; then
    log "Aktiverar Tailscale auto-update"
    tailscale set --auto-update 2>/dev/null || warn "tailscale set --auto-update misslyckades"
  fi

  local ts_host=""
  if [[ -n "$CUSTOMER" ]]; then
    ts_host="autodarts-${CUSTOMER}"
  fi

  if tailscale status 2>/dev/null | grep -qE '^[0-9a-f.:]+[[:space:]]+'; then
    log "Tailscale redan ansluten"
    return
  fi

  local up_args=()
  if [[ -n "$ts_host" ]]; then
    up_args+=(--hostname="$ts_host")
  fi
  if [[ -n "$TS_AUTHKEY" ]]; then
    up_args+=(--auth-key="$TS_AUTHKEY")
    log "Ansluter Tailscale (auth key från TS_AUTHKEY)..."
    tailscale up "${up_args[@]}"
  else
    log "Ansluter Tailscale — följ login-URL nedan (ingen TS_AUTHKEY satt)"
    # Intentionally allow this to print the URL to the operator
    tailscale up "${up_args[@]}" || true
    warn "Om du inte ser en URL, kör: sudo tailscale up"
  fi
}

install_autodarts_headless() {
  apt_install_if_missing curl ca-certificates
  local extra_args=()
  if [[ "$AUTODARTS_BETA" == "1" ]]; then
    extra_args+=(--beta)
  fi
  log "Installerar Autodarts headless (officiellt) för användare ${BOARD_USER}"
  # Official installer must run without sudo; re-run is supported.
  run_as_board_user "curl -fsSL '${AUTODARTS_INSTALL_URL}' | bash -s -- --headless ${extra_args[*]:-}"
}

enable_user_linger() {
  if loginctl show-user "$BOARD_USER" -p Linger --value 2>/dev/null | grep -qx yes; then
    log "systemd linger redan aktiverat för ${BOARD_USER}"
  else
    log "Aktiverar systemd linger för ${BOARD_USER} (tjänster vid boot utan inloggning)"
    loginctl enable-linger "$BOARD_USER"
  fi
}

install_uvc_hack() {
  if [[ "$INSTALL_UVC_HACK" != "1" ]]; then
    return
  fi
  log "Installerar UVC-hack (rekommenderat vid flera USB-kameror)"
  warn "UVC-hack fungerar inte med UEFI Secure Boot aktiverat"
  apt_install_if_missing curl build-essential
  bash -c "$(curl -fsSL https://get.autodarts.com/uvc)"
}

install_autodarts_update_timer() {
  # Headless Autodarts does not auto-update; use weekly official CLI updater.
  local unit_path="/etc/systemd/system/autodarts-update.service"
  local timer_path="/etc/systemd/system/autodarts-update.timer"
  local home
  home="$(board_home)"

  log "Installerar veckovis systemd-timer för 'autodarts update'"

  cat > "$unit_path" <<EOF
[Unit]
Description=Autodarts headless update (weekly)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=${BOARD_USER}
Group=${BOARD_USER}
WorkingDirectory=${home}
Environment=HOME=${home}
Environment=USER=${BOARD_USER}
ExecStart=${home}/.local/bin/autodarts update
EOF

  cat > "$timer_path" <<'EOF'
[Unit]
Description=Weekly Autodarts update (night)

[Timer]
OnCalendar=Sun *-*-* 03:30:00
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now autodarts-update.timer
  log "Timer aktiv: systemctl status autodarts-update.timer"
}

print_next_steps() {
  cat <<EOF

${LOG_PREFIX} --- Klart (v0.1) ---

Autodarts är installerat för ${BOARD_USER}. Själva board-tjänsten sätts upp i Autodarts
interaktiva gränssnitt (en gång):

  sudo -u ${BOARD_USER} -H bash -lc 'autodarts'

  • Logga in / skanna QR, kalibrera kameror
  • I menyn "Service": installera tjänsten så brädet startar vid boot

Loggar (efter tjänsten är installerad):
  sudo -u ${BOARD_USER} journalctl --user -u autodarts.service -f

Uppdateringar:
  • OS: unattended-upgrades (säkerhet)
  • Autodarts: veckovis timer (söndag ~03:30) kör \`autodarts update\`
  • Manuellt: sudo -u ${BOARD_USER} -H autodarts update
  • Docs: https://autodarts.diy/getting-started/installation/

Tailscale: sudo tailscale status
  Maskinens namn i Tailscale: ${CUSTOMER:+autodarts-${CUSTOMER}}${CUSTOMER:-(standard)}

Dokumentation: https://github.com/WilliamLundqvist/autodarts-setup

EOF
}

main() {
  log "Startar Autodarts Pi-installation (v0.1)"
  require_root
  require_pi_arm64
  require_board_user

  apt_install_if_missing sudo ca-certificates

  configure_hostname
  configure_timezone
  configure_unattended_upgrades
  disable_unneeded_services
  install_tailscale
  install_autodarts_headless
  enable_user_linger
  install_uvc_hack
  install_autodarts_update_timer

  print_next_steps
  log "Installation finished."
}

main "$@"
