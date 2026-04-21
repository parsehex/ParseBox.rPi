#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
XORG_FBDEV_TEMPLATE_FILE="${TEMPLATE_DIR}/xorg.99-fbdev.conf"
XORG_TOUCH_TEMPLATE_FILE="${TEMPLATE_DIR}/xorg.98-touch-calibration.conf.template"
RESTART_FB_IMAGE_TEMPLATE_FILE="${TEMPLATE_DIR}/restarting.480x320.rgb565le.raw"

PI_HOST="${PI_HOST:-raspberrypi}"
PI_USER="${PI_USER:-user}"
PI_PORT="${PI_PORT:-22}"
SSH_OPTS="${SSH_OPTS:-}"

if [[ -z "${PI_HOST}" ]]; then
  echo "Set PI_HOST. Example: PI_HOST=raspberrypi.local bash scripts/pi/setup-system.sh"
  exit 1
fi

if ! command -v ssh >/dev/null 2>&1; then
  echo "ssh is required on the local machine."
  exit 1
fi

for template_file in \
  "${XORG_FBDEV_TEMPLATE_FILE}" \
  "${XORG_TOUCH_TEMPLATE_FILE}" \
  "${RESTART_FB_IMAGE_TEMPLATE_FILE}"
do
  if [[ ! -f "${template_file}" ]]; then
    echo "Missing template file: ${template_file}"
    exit 1
  fi
done

ENABLE_TTY_AUTOLOGIN="${ENABLE_TTY_AUTOLOGIN:-1}"
INSTALL_NODE="${INSTALL_NODE:-1}"
ENABLE_FBCON_MAP="${ENABLE_FBCON_MAP:-1}"
ENABLE_CLEAR_FB_SHUTDOWN="${ENABLE_CLEAR_FB_SHUTDOWN:-1}"
ENABLE_PARSEBOX_POWER_CONTROLS="${ENABLE_PARSEBOX_POWER_CONTROLS:-1}"
NODE_CHANNEL="${NODE_CHANNEL:-lts}"
TOUCH_CALIBRATION_MATRIX="${TOUCH_CALIBRATION_MATRIX:-1 0 0 0 -1 1 0 0 1}"

XORG_FBDEV_TEMPLATE_B64="$(base64 "${XORG_FBDEV_TEMPLATE_FILE}" | tr -d '\n')"
XORG_TOUCH_TEMPLATE_B64="$(base64 "${XORG_TOUCH_TEMPLATE_FILE}" | tr -d '\n')"

TARGET="${PI_USER}@${PI_HOST}"

if [[ -n "${SSH_OPTS}" ]]; then
  # shellcheck disable=SC2206
  EXTRA_SSH_OPTS=(${SSH_OPTS})
else
  EXTRA_SSH_OPTS=()
fi

echo "Running remote system setup on ${TARGET}:${PI_PORT}"

REMOTE_SCRIPT_B64="$(base64 <<'REMOTE_SCRIPT' | tr -d '\n'
set -euo pipefail

ENABLE_TTY_AUTOLOGIN="${ENABLE_TTY_AUTOLOGIN:-1}"
INSTALL_NODE="${INSTALL_NODE:-1}"
ENABLE_FBCON_MAP="${ENABLE_FBCON_MAP:-0}"
ENABLE_CLEAR_FB_SHUTDOWN="${ENABLE_CLEAR_FB_SHUTDOWN:-1}"
ENABLE_PARSEBOX_POWER_CONTROLS="${ENABLE_PARSEBOX_POWER_CONTROLS:-1}"
NODE_CHANNEL="${NODE_CHANNEL:-lts}"
TOUCH_CALIBRATION_MATRIX="${TOUCH_CALIBRATION_MATRIX:-1 0 0 0 -1 1 0 0 1}"
KIOSK_USER="${KIOSK_USER:-user}"
RESTART_FB_IMAGE_FILE="/usr/local/share/parsebox/restarting.480x320.rgb565le.raw"
RESTART_FB_IMAGE_SOURCE_FILE="/tmp/parsebox/restarting.480x320.rgb565le.raw"

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

TOUCH_CALIBRATION_MATRIX_ESC="$(escape_sed_replacement "${TOUCH_CALIBRATION_MATRIX}")"

BOOT_CONFIG_FILE=""
for candidate in /boot/firmware/config.txt; do
  if [[ -f "${candidate}" ]]; then
    BOOT_CONFIG_FILE="${candidate}"
    break
  fi
done

BOOT_CMDLINE_FILE=""
for candidate in /boot/firmware/cmdline.txt; do
  if [[ -f "${candidate}" ]]; then
    BOOT_CMDLINE_FILE="${candidate}"
    break
  fi
done

if [[ -z "${BOOT_CONFIG_FILE}" || -z "${BOOT_CMDLINE_FILE}" ]]; then
  echo "Could not find boot config or cmdline files."
  exit 1
fi

append_unique_line() {
  local target_file="$1"
  local line="$2"
  if ! grep -Fqx "${line}" "${target_file}"; then
    echo "${line}" >>"${target_file}"
  fi
}

append_cmdline_token() {
  local token="$1"
  if ! grep -Fq "${token}" "${BOOT_CMDLINE_FILE}"; then
    sed -i "1 s|$| ${token}|" "${BOOT_CMDLINE_FILE}"
  fi
}

echo "[1/7] Updating system packages"
apt update
apt full-upgrade -y

echo "[2/7] Installing base packages"
apt install -y \
  git curl ca-certificates \
  xauth xinit xserver-xorg openbox unclutter x11-xserver-utils \
  chromium

if [[ "${INSTALL_NODE}" == "1" ]]; then
  echo "[3/7] Installing Node.js (${NODE_CHANNEL})"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_CHANNEL}.x" | bash -
  apt install -y nodejs
else
  echo "[3/7] Skipping Node.js install (INSTALL_NODE=${INSTALL_NODE})"
fi

echo "[4/7] Writing Xorg and touch configs"
mkdir -p /etc/X11/xorg.conf.d

printf '%s' "${XORG_FBDEV_TEMPLATE_B64}" | base64 -d >/etc/X11/xorg.conf.d/99-fbdev.conf
printf '%s' "${XORG_TOUCH_TEMPLATE_B64}" | base64 -d \
  | sed -e "s|__TOUCH_CALIBRATION_MATRIX__|${TOUCH_CALIBRATION_MATRIX_ESC}|g" >/etc/X11/xorg.conf.d/98-touch-calibration.conf

echo "[5/7] Updating boot config"
append_unique_line "${BOOT_CONFIG_FILE}" "dtparam=spi=on"
append_unique_line "${BOOT_CONFIG_FILE}" "dtoverlay=piscreen,speed=16000000"

if [[ "${ENABLE_FBCON_MAP}" == "1" ]]; then
  append_cmdline_token "fbcon=map:10"
fi

echo "[6/7] Installing framebuffer clear-on-shutdown service"
if [[ "${ENABLE_CLEAR_FB_SHUTDOWN}" == "1" ]]; then
  mkdir -p /usr/local/share/parsebox
  if [[ -r "${RESTART_FB_IMAGE_SOURCE_FILE}" ]]; then
    cp "${RESTART_FB_IMAGE_SOURCE_FILE}" "${RESTART_FB_IMAGE_FILE}"
  else
    echo "Warning: restart framebuffer image source missing at ${RESTART_FB_IMAGE_SOURCE_FILE}; using zero clear fallback."
  fi

  cat >/usr/local/bin/clear-fb1.sh <<'EOF'
#!/usr/bin/env sh
FB=/dev/fb1
SYS=/sys/class/graphics/fb1
RESTART_FB_IMAGE_FILE=/usr/local/share/parsebox/restarting.480x320.rgb565le.raw

if [ -e "$FB" ] && [ -r "$SYS/virtual_size" ] && [ -r "$SYS/bits_per_pixel" ]; then
  IFS=, read -r W H < "$SYS/virtual_size"
  BPP=$(cat "$SYS/bits_per_pixel")
  SIZE=$((W * H * BPP / 8))

  if [ "$W" = "480" ] && [ "$H" = "320" ] && [ "$BPP" = "16" ] && [ -r "$RESTART_FB_IMAGE_FILE" ]; then
    dd if="$RESTART_FB_IMAGE_FILE" of="$FB" bs="$SIZE" count=1 status=none || true
  else
    dd if=/dev/zero of="$FB" bs="$SIZE" count=1 status=none || true
  fi
fi
EOF
  chmod +x /usr/local/bin/clear-fb1.sh

  cat >/etc/systemd/system/clear-fb1-on-shutdown.service <<'EOF'
[Unit]
Description=Clear SPI framebuffer on shutdown/reboot
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/clear-fb1.sh

[Install]
WantedBy=shutdown.target reboot.target halt.target
EOF

  systemctl daemon-reload
  systemctl enable clear-fb1-on-shutdown.service
else
  echo "Skipping framebuffer clear service (ENABLE_CLEAR_FB_SHUTDOWN=${ENABLE_CLEAR_FB_SHUTDOWN})"
fi

echo "[7/8] Configuring ParseBox power-control permissions"
if [[ "${ENABLE_PARSEBOX_POWER_CONTROLS}" == "1" ]]; then
  cat >/etc/sudoers.d/parsebox-kiosk-controls <<EOF
Cmnd_Alias PARSEBOX_POWER = /usr/bin/systemctl reboot, /usr/bin/systemctl poweroff
Cmnd_Alias PARSEBOX_SWITCH = /usr/bin/systemctl restart getty@tty1.service, /usr/local/bin/parsebox-install-plymouth-theme *
${KIOSK_USER} ALL=(root) NOPASSWD: PARSEBOX_POWER, PARSEBOX_SWITCH
EOF
  chmod 440 /etc/sudoers.d/parsebox-kiosk-controls
else
  echo "Skipping power-control sudoers config (ENABLE_PARSEBOX_POWER_CONTROLS=${ENABLE_PARSEBOX_POWER_CONTROLS})"
fi

echo "[8/8] Configuring tty1 autologin"
if [[ "${ENABLE_TTY_AUTOLOGIN}" == "1" ]]; then
  if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint do_boot_behaviour B2 || true
  else
    echo "raspi-config not available; skipped autologin configuration."
  fi
else
  echo "Skipping autologin config (ENABLE_TTY_AUTOLOGIN=${ENABLE_TTY_AUTOLOGIN})"
fi

echo
echo "System setup complete."
echo "Next, run as kiosk user (without sudo):"
echo "  PI_HOST=<host> PI_USER=<user> bash scripts/pi/setup-kiosk-user.sh"
REMOTE_SCRIPT
)"

if [[ "${ENABLE_CLEAR_FB_SHUTDOWN}" == "1" ]]; then
  echo "Uploading restart framebuffer template"
  cat "${RESTART_FB_IMAGE_TEMPLATE_FILE}" | ssh -p "${PI_PORT}" "${EXTRA_SSH_OPTS[@]}" "${TARGET}" "mkdir -p /tmp/parsebox && cat > /tmp/parsebox/restarting.480x320.rgb565le.raw"
fi

REMOTE_RUNNER="sudo ENABLE_TTY_AUTOLOGIN=${ENABLE_TTY_AUTOLOGIN@Q} INSTALL_NODE=${INSTALL_NODE@Q} ENABLE_FBCON_MAP=${ENABLE_FBCON_MAP@Q} ENABLE_CLEAR_FB_SHUTDOWN=${ENABLE_CLEAR_FB_SHUTDOWN@Q} ENABLE_PARSEBOX_POWER_CONTROLS=${ENABLE_PARSEBOX_POWER_CONTROLS@Q} NODE_CHANNEL=${NODE_CHANNEL@Q} KIOSK_USER=${PI_USER@Q} TOUCH_CALIBRATION_MATRIX=${TOUCH_CALIBRATION_MATRIX@Q} XORG_FBDEV_TEMPLATE_B64=${XORG_FBDEV_TEMPLATE_B64@Q} XORG_TOUCH_TEMPLATE_B64=${XORG_TOUCH_TEMPLATE_B64@Q} bash -c \"printf %s ${REMOTE_SCRIPT_B64@Q} | base64 -d | bash\""
ssh -tt -p "${PI_PORT}" "${EXTRA_SSH_OPTS[@]}" "${TARGET}" "${REMOTE_RUNNER}"
