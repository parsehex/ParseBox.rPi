#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
XORG_FBDEV_TEMPLATE_FILE="${TEMPLATE_DIR}/xorg.99-fbdev.conf"
XORG_TOUCH_TEMPLATE_FILE="${TEMPLATE_DIR}/xorg.98-touch-calibration.conf.template"

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
  "${XORG_TOUCH_TEMPLATE_FILE}"
do
  if [[ ! -f "${template_file}" ]]; then
    echo "Missing template file: ${template_file}"
    exit 1
  fi
done

ENABLE_TTY_AUTOLOGIN="${ENABLE_TTY_AUTOLOGIN:-1}"
INSTALL_NODE="${INSTALL_NODE:-1}"
ENABLE_FBCON_MAP="${ENABLE_FBCON_MAP:-1}"
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
NODE_CHANNEL="${NODE_CHANNEL:-lts}"
TOUCH_CALIBRATION_MATRIX="${TOUCH_CALIBRATION_MATRIX:-1 0 0 0 -1 1 0 0 1}"

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

echo "[1/6] Updating system packages"
apt update
apt full-upgrade -y

echo "[2/6] Installing base packages"
apt install -y \
  git curl ca-certificates \
  xauth xinit xserver-xorg openbox unclutter x11-xserver-utils \
  chromium

if [[ "${INSTALL_NODE}" == "1" ]]; then
  echo "[3/6] Installing Node.js (${NODE_CHANNEL})"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_CHANNEL}.x" | bash -
  apt install -y nodejs
else
  echo "[3/6] Skipping Node.js install (INSTALL_NODE=${INSTALL_NODE})"
fi

echo "[4/6] Writing Xorg and touch configs"
mkdir -p /etc/X11/xorg.conf.d

printf '%s' "${XORG_FBDEV_TEMPLATE_B64}" | base64 -d >/etc/X11/xorg.conf.d/99-fbdev.conf
printf '%s' "${XORG_TOUCH_TEMPLATE_B64}" | base64 -d \
  | sed -e "s|__TOUCH_CALIBRATION_MATRIX__|${TOUCH_CALIBRATION_MATRIX_ESC}|g" >/etc/X11/xorg.conf.d/98-touch-calibration.conf

echo "[5/6] Updating boot config"
append_unique_line "${BOOT_CONFIG_FILE}" "dtparam=spi=on"
append_unique_line "${BOOT_CONFIG_FILE}" "dtoverlay=piscreen,speed=16000000"

if [[ "${ENABLE_FBCON_MAP}" == "1" ]]; then
  append_cmdline_token "fbcon=map:10"
fi

echo "[6/6] Configuring tty1 autologin"
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

REMOTE_RUNNER="sudo ENABLE_TTY_AUTOLOGIN=${ENABLE_TTY_AUTOLOGIN@Q} INSTALL_NODE=${INSTALL_NODE@Q} ENABLE_FBCON_MAP=${ENABLE_FBCON_MAP@Q} NODE_CHANNEL=${NODE_CHANNEL@Q} TOUCH_CALIBRATION_MATRIX=${TOUCH_CALIBRATION_MATRIX@Q} XORG_FBDEV_TEMPLATE_B64=${XORG_FBDEV_TEMPLATE_B64@Q} XORG_TOUCH_TEMPLATE_B64=${XORG_TOUCH_TEMPLATE_B64@Q} bash -c \"printf %s ${REMOTE_SCRIPT_B64@Q} | base64 -d | bash\""
ssh -tt -p "${PI_PORT}" "${EXTRA_SSH_OPTS[@]}" "${TARGET}" "${REMOTE_RUNNER}"
