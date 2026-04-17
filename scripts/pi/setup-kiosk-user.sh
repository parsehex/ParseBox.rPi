#!/usr/bin/env bash

set -euo pipefail

PI_HOST="${PI_HOST:-raspberrypi}"
PI_USER="${PI_USER:-user}"
PI_PORT="${PI_PORT:-22}"
SSH_OPTS="${SSH_OPTS:-}"

if [[ -z "${PI_HOST}" ]]; then
  echo "Set PI_HOST. Example: PI_HOST=raspberrypi.local bash scripts/pi/setup-kiosk-user.sh"
  exit 1
fi

if ! command -v ssh >/dev/null 2>&1; then
  echo "ssh is required on the local machine."
  exit 1
fi

APP_URL="${APP_URL:-http://127.0.0.1:4174/}"
WAIT_URL="${WAIT_URL:-${APP_URL}}"
FORCE="${FORCE:-0}"
REPO_URL="${REPO_URL:-https://github.com/parsehex/ParseBox.rPi.git}"
REPO_DIR="${REPO_DIR:-}"

TARGET="${PI_USER}@${PI_HOST}"

if [[ -n "${SSH_OPTS}" ]]; then
  # shellcheck disable=SC2206
  EXTRA_SSH_OPTS=(${SSH_OPTS})
else
  EXTRA_SSH_OPTS=()
fi

echo "Running remote kiosk-user setup on ${TARGET}:${PI_PORT}"

REMOTE_SCRIPT_B64="$(cat <<'REMOTE_SCRIPT' | base64 | tr -d '\n'
set -euo pipefail

APP_URL="${APP_URL:-http://127.0.0.1:4174/}"
WAIT_URL="${WAIT_URL:-${APP_URL}}"
FORCE="${FORCE:-0}"
REPO_URL="${REPO_URL:-https://github.com/parsehex/ParseBox.rPi.git}"
REPO_DIR="${REPO_DIR:-${HOME}/ParseBox.rPi}"

if [[ "${EUID}" -eq 0 ]]; then
  echo "Remote user is root. Use a normal user account for kiosk profile setup."
  exit 1
fi

echo "[0/3] Cloning repo"
if [[ -d "${REPO_DIR}/.git" ]]; then
  echo "  Repo exists, pulling latest"
  git -C "${REPO_DIR}" pull --ff-only
else
  git clone "${REPO_URL}" "${REPO_DIR}"
fi

echo "[0/3] Installing kiosk server systemd unit"
SERVICE_FILE="${HOME}/.config/systemd/user/parsebox-kiosk.service"
mkdir -p "$(dirname "${SERVICE_FILE}")"
cat >"${SERVICE_FILE}" <<EOF
[Unit]
Description=ParseBox kiosk HTTP server
After=network.target

[Service]
ExecStart=/usr/bin/python3 -m http.server 4174 --directory ${REPO_DIR}/kiosk
Restart=on-failure

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now parsebox-kiosk.service
# ensure lingering so the user service starts at boot without a login session
loginctl enable-linger "$(id -un)" 2>/dev/null || true

PROFILE_FILE="${HOME}/.profile"
XINITRC_FILE="${HOME}/.xinitrc"

if [[ ! -f "${PROFILE_FILE}" ]]; then
  touch "${PROFILE_FILE}"
fi

echo "[1/3] Ensuring kiosk login hook in ${PROFILE_FILE}"
if ! grep -Fq "PARSEBOX_RPI_KIOSK_START" "${PROFILE_FILE}"; then
  cat >>"${PROFILE_FILE}" <<'EOF'

# PARSEBOX_RPI_KIOSK_START
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ] && [ ! -f "$HOME/.no-kiosk" ]; then
  exec startx "$HOME/.xinitrc" -- :0 vt1 -keeptty
fi
# PARSEBOX_RPI_KIOSK_END
EOF
fi

if [[ -f "${XINITRC_FILE}" && "${FORCE}" != "1" ]]; then
  echo "${XINITRC_FILE} exists. Set FORCE=1 to overwrite."
  exit 0
fi

echo "[2/3] Writing ${XINITRC_FILE}"
cat >"${XINITRC_FILE}" <<EOF
#!/usr/bin/env sh
xset -dpms
xset s off
xset s noblank
unclutter -idle 0.5 -root &

until curl -fsS "${WAIT_URL}" >/dev/null; do
  sleep 1
done

sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' "\$HOME/.config/chromium/Local State" 2>/dev/null || true
sed -i 's/"exited_cleanly":false/"exited_cleanly":true/; s/"exit_type":"[^"]\+"/"exit_type":"Normal"/' "\$HOME/.config/chromium/Default/Preferences" 2>/dev/null || true

exec chromium \
  --kiosk \
  --app="${APP_URL}" \
  --force-device-scale-factor=1 \
  --disable-infobars \
  --disable-gpu \
  --use-gl=swiftshader \
  --no-first-run \
  --disable-pinch \
  --overscroll-history-navigation=0 \
  --start-maximized
EOF

chmod +x "${XINITRC_FILE}"

echo
echo "Kiosk user setup complete."
echo "To disable kiosk temporarily: touch ~/.no-kiosk"
REMOTE_SCRIPT
)"

REMOTE_RUNNER="APP_URL=${APP_URL@Q} WAIT_URL=${WAIT_URL@Q} FORCE=${FORCE@Q} REPO_URL=${REPO_URL@Q} REPO_DIR=${REPO_DIR@Q} bash -c \"printf %s ${REMOTE_SCRIPT_B64@Q} | base64 -d | bash\""
ssh -tt -p "${PI_PORT}" "${EXTRA_SSH_OPTS[@]}" "${TARGET}" "${REMOTE_RUNNER}"
