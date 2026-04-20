#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
XINITRC_TEMPLATE_FILE="${TEMPLATE_DIR}/kiosk.xinitrc.template"
PROFILE_HOOK_TEMPLATE_FILE="${TEMPLATE_DIR}/profile-kiosk-hook.sh"
SERVICE_TEMPLATE_FILE="${TEMPLATE_DIR}/parsebox-kiosk.service.template"

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

for template_file in \
  "${XINITRC_TEMPLATE_FILE}" \
  "${PROFILE_HOOK_TEMPLATE_FILE}" \
  "${SERVICE_TEMPLATE_FILE}"
do
  if [[ ! -f "${template_file}" ]]; then
    echo "Missing template file: ${template_file}"
    exit 1
  fi
done

APP_URL="${APP_URL:-http://127.0.0.1:4174/}"
WAIT_URL="${WAIT_URL:-http://127.0.0.1:4174/health}"
FORCE="${FORCE:-0}"
REPO_URL="${REPO_URL:-https://github.com/parsehex/ParseBox.rPi.git}"
REPO_DIR="${REPO_DIR:-}"
SERVICE_HTTP_PORT="${SERVICE_HTTP_PORT:-4174}"
SERVICE_HTTP_DIRECTORY="${SERVICE_HTTP_DIRECTORY:-}"
PARSEBOX_CONFIG_FILE="${PARSEBOX_CONFIG_FILE:-}"

XINITRC_TEMPLATE_B64="$(base64 "${XINITRC_TEMPLATE_FILE}" | tr -d '\n')"
PROFILE_HOOK_TEMPLATE_B64="$(base64 "${PROFILE_HOOK_TEMPLATE_FILE}" | tr -d '\n')"
SERVICE_TEMPLATE_B64="$(base64 "${SERVICE_TEMPLATE_FILE}" | tr -d '\n')"

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
WAIT_URL="${WAIT_URL:-http://127.0.0.1:4174/health}"
FORCE="${FORCE:-0}"
REPO_URL="${REPO_URL:-https://github.com/parsehex/ParseBox.rPi.git}"
REPO_DIR="${REPO_DIR:-${HOME}/ParseBox.rPi}"
SERVICE_HTTP_PORT="${SERVICE_HTTP_PORT:-4174}"
SERVICE_HTTP_DIRECTORY="${SERVICE_HTTP_DIRECTORY:-${REPO_DIR}/kiosk}"
PARSEBOX_CONFIG_FILE="${PARSEBOX_CONFIG_FILE:-${HOME}/.parsebox/config.json}"

if [[ "${EUID}" -eq 0 ]]; then
  echo "Remote user is root. Use a normal user account for kiosk profile setup."
  exit 1
fi

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

escape_json_string() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

APP_URL_ESC="$(escape_sed_replacement "${APP_URL}")"
WAIT_URL_ESC="$(escape_sed_replacement "${WAIT_URL}")"
SERVER_ENTRYPOINT="${REPO_DIR}/server/index.ts"
SERVER_ENTRYPOINT_ESC="$(escape_sed_replacement "${SERVER_ENTRYPOINT}")"
SERVER_CONFIG_ESC="$(escape_sed_replacement "${PARSEBOX_CONFIG_FILE}")"
SERVICE_HTTP_DIRECTORY_JSON="$(escape_json_string "${SERVICE_HTTP_DIRECTORY}")"
APP_URL_JSON="$(escape_json_string "${APP_URL}")"

echo "[0/3] Cloning repo"
if [[ -d "${REPO_DIR}/.git" ]]; then
  echo "  Repo exists, pulling latest"
  git -C "${REPO_DIR}" pull --ff-only
else
  git clone "${REPO_URL}" "${REPO_DIR}"
fi

echo "[0/3] Writing ParseBox runtime config"
mkdir -p "$(dirname "${PARSEBOX_CONFIG_FILE}")"
cat >"${PARSEBOX_CONFIG_FILE}" <<EOF
{
  "port": ${SERVICE_HTTP_PORT},
  "staticDir": "${SERVICE_HTTP_DIRECTORY_JSON}",
  "appUrl": "${APP_URL_JSON}",
  "allowOnlyLocalhostControl": true
}
EOF

echo "[0/3] Installing kiosk server systemd unit"
SERVICE_FILE="${HOME}/.config/systemd/user/parsebox-kiosk.service"
mkdir -p "$(dirname "${SERVICE_FILE}")"
printf '%s' "${SERVICE_TEMPLATE_B64}" | base64 -d \
  | sed -e "s|__SERVER_ENTRYPOINT__|${SERVER_ENTRYPOINT_ESC}|g" -e "s|__SERVER_CONFIG__|${SERVER_CONFIG_ESC}|g" >"${SERVICE_FILE}"

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
if ! grep -Fq "PARSEBOX_KIOSK_START" "${PROFILE_FILE}"; then
  printf '\n' >>"${PROFILE_FILE}"
  printf '%s' "${PROFILE_HOOK_TEMPLATE_B64}" | base64 -d >>"${PROFILE_FILE}"
fi

if [[ -f "${XINITRC_FILE}" && "${FORCE}" != "1" ]]; then
  echo "${XINITRC_FILE} exists. Set FORCE=1 to overwrite."
  exit 0
fi

echo "[2/3] Writing ${XINITRC_FILE}"
printf '%s' "${XINITRC_TEMPLATE_B64}" | base64 -d \
  | sed -e "s|__APP_URL__|${APP_URL_ESC}|g" -e "s|__WAIT_URL__|${WAIT_URL_ESC}|g" >"${XINITRC_FILE}"

chmod +x "${XINITRC_FILE}"

echo
echo "Kiosk user setup complete."
echo "HTTP service directory: ${SERVICE_HTTP_DIRECTORY}"
echo "HTTP service port: ${SERVICE_HTTP_PORT}"
echo "Runtime config file: ${PARSEBOX_CONFIG_FILE}"
echo "To disable kiosk temporarily: touch ~/.no-kiosk"
REMOTE_SCRIPT
)"

REMOTE_RUNNER="APP_URL=${APP_URL@Q} WAIT_URL=${WAIT_URL@Q} FORCE=${FORCE@Q} REPO_URL=${REPO_URL@Q} REPO_DIR=${REPO_DIR@Q} SERVICE_HTTP_PORT=${SERVICE_HTTP_PORT@Q} SERVICE_HTTP_DIRECTORY=${SERVICE_HTTP_DIRECTORY@Q} PARSEBOX_CONFIG_FILE=${PARSEBOX_CONFIG_FILE@Q} XINITRC_TEMPLATE_B64=${XINITRC_TEMPLATE_B64@Q} PROFILE_HOOK_TEMPLATE_B64=${PROFILE_HOOK_TEMPLATE_B64@Q} SERVICE_TEMPLATE_B64=${SERVICE_TEMPLATE_B64@Q} bash -c \"printf %s ${REMOTE_SCRIPT_B64@Q} | base64 -d | bash\""
ssh -tt -p "${PI_PORT}" "${EXTRA_SSH_OPTS[@]}" "${TARGET}" "${REMOTE_RUNNER}"
