#!/usr/bin/env bash

set -euo pipefail

PI_HOST="${PI_HOST:-raspberrypi}"
PI_USER="${PI_USER:-user}"
PI_PORT="${PI_PORT:-22}"
SSH_OPTS="${SSH_OPTS:-}"
THEME_ID="${THEME_ID:-parsebox}"
THEME_NAME="${THEME_NAME:-ParseBox}"
FRAMEBUFFER="${FRAMEBUFFER:-/dev/fb1}"
MARKER_FILE="${MARKER_FILE:-/etc/parsebox/splash-enabled}"
HELPER_BIN="${HELPER_BIN:-/usr/local/bin/parsebox-install-plymouth-theme}"

if [[ -z "${PI_HOST}" ]]; then
  echo "Set PI_HOST. Example: PI_HOST=raspberrypi.local bash scripts/pi/setup-splash.sh"
  exit 1
fi

if ! command -v ssh >/dev/null 2>&1; then
  echo "ssh is required on the local machine."
  exit 1
fi

TARGET="${PI_USER}@${PI_HOST}"

if [[ -n "${SSH_OPTS}" ]]; then
  # shellcheck disable=SC2206
  EXTRA_SSH_OPTS=(${SSH_OPTS})
else
  EXTRA_SSH_OPTS=()
fi

echo "Running remote splash setup on ${TARGET}:${PI_PORT}"

REMOTE_SCRIPT_B64="$(cat <<'REMOTE_SCRIPT' | base64 | tr -d '\n'
set -euo pipefail

THEME_ID="${THEME_ID:-parsebox}"
THEME_NAME="${THEME_NAME:-ParseBox}"
FRAMEBUFFER="${FRAMEBUFFER:-/dev/fb1}"
MARKER_FILE="${MARKER_FILE:-/etc/parsebox/splash-enabled}"
HELPER_BIN="${HELPER_BIN:-/usr/local/bin/parsebox-install-plymouth-theme}"

append_cmdline_token() {
  local cmdline_file="$1"
  local token="$2"
  if [[ -f "${cmdline_file}" ]] && ! grep -Fq "${token}" "${cmdline_file}"; then
    sed -i "1 s|$| ${token}|" "${cmdline_file}"
  fi
}

echo "[1/5] Installing splash dependencies"
apt update
apt install -y plymouth plymouth-themes imagemagick librsvg2-bin initramfs-tools

echo "[2/5] Installing ParseBox Plymouth helper"
cat >"${HELPER_BIN}" <<'HELPER_SCRIPT'
#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: parsebox-install-plymouth-theme --theme-id <id> --theme-name <name> --image <png|svg> [--framebuffer /dev/fb1]"
}

THEME_ID=""
THEME_NAME=""
IMAGE_FILE=""
FRAMEBUFFER="/dev/fb1"
MARKER_FILE="/etc/parsebox/splash-enabled"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --theme-id)
      THEME_ID="$2"
      shift 2
      ;;
    --theme-name)
      THEME_NAME="$2"
      shift 2
      ;;
    --image)
      IMAGE_FILE="$2"
      shift 2
      ;;
    --framebuffer)
      FRAMEBUFFER="$2"
      shift 2
      ;;
    --marker-file)
      MARKER_FILE="$2"
      shift 2
      ;;
    *)
      usage
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [[ -z "${THEME_ID}" || -z "${THEME_NAME}" || -z "${IMAGE_FILE}" ]]; then
  usage
  exit 1
fi

if [[ ! -f "${IMAGE_FILE}" ]]; then
  echo "Image file not found: ${IMAGE_FILE}"
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "This helper must run as root."
  exit 1
fi

THEME_DIR="/usr/share/plymouth/themes/${THEME_ID}"
mkdir -p "${THEME_DIR}"

IMAGE_EXT="${IMAGE_FILE##*.}"
IMAGE_EXT_LOWER="$(printf '%s' "${IMAGE_EXT}" | tr '[:upper:]' '[:lower:]')"
TARGET_SPLASH="${THEME_DIR}/splash.png"

if [[ "${IMAGE_EXT_LOWER}" == "svg" ]]; then
  rsvg-convert -w 480 -h 320 "${IMAGE_FILE}" -o "${TARGET_SPLASH}"
else
  cp "${IMAGE_FILE}" "${TARGET_SPLASH}"
fi

cat >"${THEME_DIR}/${THEME_ID}.plymouth" <<EOF
[Plymouth Theme]
Name=${THEME_NAME}
Description=${THEME_NAME} boot splash
ModuleName=script

[script]
ImageDir=${THEME_DIR}
ScriptFile=${THEME_DIR}/${THEME_ID}.script
EOF

cat >"${THEME_DIR}/${THEME_ID}.script" <<'EOF'
screen_w = Window.GetWidth();
screen_h = Window.GetHeight();
img = Image("splash.png");
sprite = Sprite(img);
sprite.SetX((screen_w - img.GetWidth()) / 2);
sprite.SetY((screen_h - img.GetHeight()) / 2);
EOF

update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth "${THEME_DIR}/${THEME_ID}.plymouth" 100
update-alternatives --set default.plymouth "${THEME_DIR}/${THEME_ID}.plymouth"

cat >/etc/plymouth/plymouthd.conf <<EOF
[Daemon]
Theme=${THEME_ID}
DeviceTimeout=8
ShowDelay=0
Framebuffer=${FRAMEBUFFER}
EOF

BOOT_CMDLINE_FILE=""
for candidate in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
  if [[ -f "${candidate}" ]]; then
    BOOT_CMDLINE_FILE="${candidate}"
    break
  fi
done

if [[ -n "${BOOT_CMDLINE_FILE}" ]]; then
  # Plymouth splash should own the panel; remove legacy console mapping token.
  sed -i -E 's/(^| )fbcon=map:10( |$)/ /g; s/[[:space:]]+/ /g; s/^ //; s/ $//' "${BOOT_CMDLINE_FILE}"

  if ! grep -Fq "splash" "${BOOT_CMDLINE_FILE}"; then
    sed -i "1 s|$| splash|" "${BOOT_CMDLINE_FILE}"
  fi
  if ! grep -Fq "plymouth.ignore-serial-consoles" "${BOOT_CMDLINE_FILE}"; then
    sed -i "1 s|$| plymouth.ignore-serial-consoles|" "${BOOT_CMDLINE_FILE}"
  fi
fi

update-initramfs -u

mkdir -p "$(dirname "${MARKER_FILE}")"
cat >"${MARKER_FILE}" <<EOF
ENABLED=1
THEME_ID=${THEME_ID}
FRAMEBUFFER=${FRAMEBUFFER}
UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

echo "Installed Plymouth theme: ${THEME_ID}"
echo "Marker file: ${MARKER_FILE}"
HELPER_SCRIPT

chmod +x "${HELPER_BIN}"

echo "[3/5] Building ParseBox splash image"
TMP_SPLASH_PNG="$(mktemp /tmp/parsebox-splash.XXXXXX.png)"
convert -size 480x320 gradient:'#0c4a6e-#111827' \
  -fill '#f8fafc' -gravity center -pointsize 54 -annotate +0-12 'ParseBox' \
  -fill '#bae6fd' -pointsize 20 -annotate +0+50 'Raspberry Pi Kiosk' \
  "${TMP_SPLASH_PNG}"

echo "[4/5] Installing ParseBox splash theme"
"${HELPER_BIN}" \
  --theme-id "${THEME_ID}" \
  --theme-name "${THEME_NAME}" \
  --image "${TMP_SPLASH_PNG}" \
  --framebuffer "${FRAMEBUFFER}" \
  --marker-file "${MARKER_FILE}"
rm -f "${TMP_SPLASH_PNG}"

echo "[5/5] Splash setup complete (fbcon=map:10 removed if present)"
REMOTE_SCRIPT
)"

REMOTE_RUNNER="sudo THEME_ID=${THEME_ID@Q} THEME_NAME=${THEME_NAME@Q} FRAMEBUFFER=${FRAMEBUFFER@Q} MARKER_FILE=${MARKER_FILE@Q} HELPER_BIN=${HELPER_BIN@Q} bash -c \"printf %s ${REMOTE_SCRIPT_B64@Q} | base64 -d | bash\""
ssh -tt -p "${PI_PORT}" "${EXTRA_SSH_OPTS[@]}" "${TARGET}" "${REMOTE_RUNNER}"
