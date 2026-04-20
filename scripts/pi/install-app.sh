#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PI_HOST="${PI_HOST:-raspberrypi}"
PI_USER="${PI_USER:-user}"
PI_PORT="${PI_PORT:-22}"
SSH_OPTS="${SSH_OPTS:-}"

APP_ID="${APP_ID:-}"
APP_REPO="${APP_REPO:-}"
APP_REPO_DIR="${APP_REPO_DIR:-}"
APP_REF="${APP_REF:-}"
SPLASH_MARKER_FILE="${SPLASH_MARKER_FILE:-/etc/parsebox/splash-enabled}"
RESTART_TTY_ON_UPDATE="${RESTART_TTY_ON_UPDATE:-1}"
SERVICE_HTTP_PORT="${SERVICE_HTTP_PORT:-4174}"
WAIT_URL="${WAIT_URL:-http://127.0.0.1:${SERVICE_HTTP_PORT}/}"
APP_URL="${APP_URL:-${WAIT_URL}}"
FORCE="${FORCE:-0}"

if [[ -z "${PI_HOST}" ]]; then
  echo "Set PI_HOST. Example: PI_HOST=raspberrypi.local bash scripts/pi/install-app.sh"
  exit 1
fi

if ! command -v ssh >/dev/null 2>&1; then
  echo "ssh is required on the local machine."
  exit 1
fi

if [[ -z "${APP_ID}" ]]; then
  echo
  echo "Select app to install"
  echo "  1) WeatherSpective"
  echo "  2) Custom"
  read -r -p "Enter choice [1/2]: " APP_CHOICE
  case "${APP_CHOICE}" in
    1|"" ) APP_ID="weatherspective" ;;
    2 ) APP_ID="custom" ;;
    * )
      echo "Invalid choice: ${APP_CHOICE}"
      exit 1
      ;;
  esac
fi

if [[ -z "${APP_REPO}" ]]; then
  case "${APP_ID}" in
    weatherspective)
      APP_REPO="https://github.com/parsehex/WeatherSpective.git"
      ;;
    custom)
      APP_REPO=""
      ;;
    *)
      APP_REPO=""
      ;;
  esac
fi

if [[ -z "${APP_REPO}" ]]; then
  read -r -p "Repository URL (or owner/repo): " APP_REPO
fi

if [[ -z "${APP_REPO}" ]]; then
  echo "Repository is required."
  exit 1
fi

if [[ "${APP_REPO}" != *"://"* && "${APP_REPO}" != git@* ]]; then
  APP_REPO="https://github.com/${APP_REPO}.git"
fi

if [[ -z "${APP_REPO_DIR}" ]]; then
  APP_SLUG_FROM_REPO="$(basename "${APP_REPO}" .git | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-')"
  APP_REPO_DIR="/home/${PI_USER}/apps/${APP_SLUG_FROM_REPO}"
fi

TARGET="${PI_USER}@${PI_HOST}"

if [[ -n "${SSH_OPTS}" ]]; then
  # shellcheck disable=SC2206
  EXTRA_SSH_OPTS=(${SSH_OPTS})
else
  EXTRA_SSH_OPTS=()
fi

echo "Running remote app install on ${TARGET}:${PI_PORT}"

REMOTE_SCRIPT_B64="$(cat <<'REMOTE_SCRIPT' | base64 | tr -d '\n'
set -euo pipefail

APP_REPO="${APP_REPO:?APP_REPO is required}"
APP_REPO_DIR="${APP_REPO_DIR:?APP_REPO_DIR is required}"
APP_REF="${APP_REF:-}"
APP_ID="${APP_ID:-custom}"
SPLASH_MARKER_FILE="${SPLASH_MARKER_FILE:-/etc/parsebox/splash-enabled}"
RESULT_FILE="${RESULT_FILE:-${HOME}/.parsebox/install-result.env}"
REPO_ALREADY_PRESENT=0
APP_UPDATED=0
INITIAL_HEAD=""

mkdir -p "$(dirname "${RESULT_FILE}")"

if [[ "${EUID}" -eq 0 ]]; then
  echo "Remote user is root. Use a normal user account for app install and kiosk profile setup."
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git is required on remote host. Run setup-system first."
  exit 1
fi

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

sync_env_from_example() {
  local env_prompt key value current_line current_value trimmed_value
  local input_value replacement_line replacement_line_esc needs_prompt

  env_prompt="${ENV_PROMPT:-1}"
  if [[ ! -f ".env.example" ]]; then
    return 0
  fi

  if [[ ! -f ".env" ]]; then
    cp .env.example .env
    echo "  Created .env from .env.example"
  fi

  if [[ "${env_prompt}" != "1" ]]; then
    return 0
  fi

  echo "  Checking .env for missing values"
  while IFS='=' read -r key value; do
    if [[ -z "${key}" || "${key}" =~ ^[[:space:]]*# ]]; then
      continue
    fi

    key="$(printf '%s' "${key}" | tr -d '[:space:]')"
    if [[ ! "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      continue
    fi

    current_line="$(grep -E "^${key}=" .env | head -n 1 || true)"
    if [[ -z "${current_line}" ]]; then
      current_value=""
    else
      current_value="${current_line#*=}"
    fi

    trimmed_value="$(printf '%s' "${current_value}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    needs_prompt=0
    if [[ -z "${trimmed_value}" || "${trimmed_value}" == '""' || "${trimmed_value}" == "''" ]]; then
      needs_prompt=1
    fi

    # Recover from a known bad state caused by line spillover in older versions.
    if [[ "${trimmed_value}" =~ ^\"?[A-Za-z_][A-Za-z0-9_]*=\"?$ ]]; then
      needs_prompt=1
    fi

    if [[ "${needs_prompt}" -ne 1 ]]; then
      continue
    fi

    if [[ -n "${!key:-}" ]]; then
      input_value="${!key}"
      echo "    Using exported value for ${key}"
    else
      if [[ -r /dev/tty ]]; then
        read -r -p "    Enter value for ${key} (leave blank to keep empty): " input_value </dev/tty
      else
        read -r -p "    Enter value for ${key} (leave blank to keep empty): " input_value
      fi
    fi

    if [[ -z "${input_value}" ]]; then
      continue
    fi

    replacement_line="${key}=${input_value}"
    replacement_line_esc="$(escape_sed_replacement "${replacement_line}")"
    if grep -q -E "^${key}=" .env; then
      sed -i -e "s|^${key}=.*$|${replacement_line_esc}|" .env
    else
      printf '\n%s\n' "${replacement_line}" >> .env
    fi
  done < .env.example
}

echo "[1/4] Syncing app repo"
if [[ -d "${APP_REPO_DIR}/.git" ]]; then
  REPO_ALREADY_PRESENT=1
  INITIAL_HEAD="$(git -C "${APP_REPO_DIR}" rev-parse HEAD 2>/dev/null || true)"
  git -C "${APP_REPO_DIR}" fetch --all --prune
  git -C "${APP_REPO_DIR}" pull --ff-only
else
  mkdir -p "$(dirname "${APP_REPO_DIR}")"
  git clone "${APP_REPO}" "${APP_REPO_DIR}"
fi

if [[ -n "${APP_REF}" ]]; then
  git -C "${APP_REPO_DIR}" checkout "${APP_REF}"
fi

if [[ "${REPO_ALREADY_PRESENT}" == "1" ]]; then
  FINAL_HEAD="$(git -C "${APP_REPO_DIR}" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "${INITIAL_HEAD}" && -n "${FINAL_HEAD}" && "${INITIAL_HEAD}" != "${FINAL_HEAD}" ]]; then
    APP_UPDATED=1
  fi
fi

cd "${APP_REPO_DIR}"

SERVE_DIR=""
APP_URL_PATH="/"

echo "[2/5] Preparing env and running installer/build"
sync_env_from_example

run_repo_installer=0
if [[ -x "./parsebox/install.sh" ]]; then
  run_repo_installer=1
  ./parsebox/install.sh
elif [[ -x "./scripts/parsebox-install.sh" ]]; then
  run_repo_installer=1
  ./scripts/parsebox-install.sh
elif [[ -x "./scripts/pi/install.sh" ]]; then
  run_repo_installer=1
  ./scripts/pi/install.sh
fi

if [[ "${run_repo_installer}" -eq 0 ]]; then
  if [[ -f "package.json" && -x "$(command -v npm || true)" ]]; then
    if [[ -f "package-lock.json" ]]; then
      npm ci
    else
      npm install
    fi

    if node -e 'const p=require("./package.json");process.exit(p.scripts && p.scripts.build ? 0 : 1)'; then
      npm run build
    fi
  fi
fi

if [[ -z "${SERVE_DIR}" ]]; then
  for candidate in dist build out public .; do
    if [[ -d "${candidate}" ]]; then
      SERVE_DIR="${APP_REPO_DIR}/${candidate}"
      break
    fi
  done
fi

if [[ -z "${SERVE_DIR}" ]]; then
  echo "Could not determine static serve directory from repo install."
  exit 1
fi

echo "[3/5] Checking app splash assets"
if [[ -f "${SPLASH_MARKER_FILE}" ]]; then
  parsebox_splash_helper="/usr/local/bin/parsebox-install-plymouth-theme"
  app_splash_image=""
  app_splash_framebuffer="/dev/fb1"
  current_theme_id=""
  app_theme_id="$(printf '%s' "${APP_ID}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-')"
  app_theme_name="${APP_ID}"

  for candidate in \
    "./parsebox/splash.png" \
    "./parsebox/splash.svg" \
    "./parsebox/splash.webp" \
    "./parsebox/splash.jpg" \
    "./parsebox/splash.jpeg"
  do
    if [[ -f "${candidate}" ]]; then
      app_splash_image="${candidate}"
      break
    fi
  done

  marker_framebuffer="$(sed -n 's/^FRAMEBUFFER=//p' "${SPLASH_MARKER_FILE}" | head -n 1 || true)"
  current_theme_id="$(sed -n 's/^THEME_ID=//p' "${SPLASH_MARKER_FILE}" | head -n 1 || true)"
  if [[ -n "${marker_framebuffer}" ]]; then
    app_splash_framebuffer="${marker_framebuffer}"
  fi

  if [[ -n "${current_theme_id}" && "${current_theme_id}" == "${app_theme_id}" ]]; then
    echo "  App splash already active (${app_theme_id}); skipping reinstall."
  elif [[ -n "${app_splash_image}" && -x "${parsebox_splash_helper}" ]]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo "${parsebox_splash_helper}" \
        --theme-id "${app_theme_id}" \
        --theme-name "${app_theme_name}" \
        --image "${app_splash_image}" \
        --framebuffer "${app_splash_framebuffer}" \
        --marker-file "${SPLASH_MARKER_FILE}"
    else
      echo "  sudo is not available; cannot install app splash theme."
    fi
  elif [[ -z "${app_splash_image}" ]]; then
    echo "  Splash is enabled but no app splash asset found."
  else
    echo "  Splash helper missing: ${parsebox_splash_helper}"
  fi
else
  echo "  Splash is not enabled. Skipping app splash install."
fi

echo "[4/5] Writing install result"
cat >"${RESULT_FILE}" <<EOF
APP_REPO_DIR=${APP_REPO_DIR}
SERVICE_HTTP_DIRECTORY=${SERVE_DIR}
APP_URL_PATH=${APP_URL_PATH}
INSTALL_WAS_UPDATE=${APP_UPDATED}
EOF

echo "[5/5] Remote app install complete"
echo "Result file: ${RESULT_FILE}"
REMOTE_SCRIPT
)"

RESULT_FILE="/home/${PI_USER}/.parsebox/install-result.env"
REMOTE_RUNNER="APP_REPO=${APP_REPO@Q} APP_REPO_DIR=${APP_REPO_DIR@Q} APP_REF=${APP_REF@Q} APP_ID=${APP_ID@Q} SPLASH_MARKER_FILE=${SPLASH_MARKER_FILE@Q} RESULT_FILE=${RESULT_FILE@Q} bash -c \"printf %s ${REMOTE_SCRIPT_B64@Q} | base64 -d | bash\""
ssh -tt -p "${PI_PORT}" "${EXTRA_SSH_OPTS[@]}" "${TARGET}" "${REMOTE_RUNNER}"

echo "Fetching install result from remote host"
RESULT_CONTENT="$(ssh -p "${PI_PORT}" "${EXTRA_SSH_OPTS[@]}" "${TARGET}" "cat ${RESULT_FILE@Q}")"

SERVICE_HTTP_DIRECTORY="$(printf '%s\n' "${RESULT_CONTENT}" | sed -n 's/^SERVICE_HTTP_DIRECTORY=//p' | head -n 1)"
APP_URL_PATH="$(printf '%s\n' "${RESULT_CONTENT}" | sed -n 's/^APP_URL_PATH=//p' | head -n 1)"
INSTALL_WAS_UPDATE="$(printf '%s\n' "${RESULT_CONTENT}" | sed -n 's/^INSTALL_WAS_UPDATE=//p' | head -n 1)"

if [[ -z "${INSTALL_WAS_UPDATE}" ]]; then
  INSTALL_WAS_UPDATE="0"
fi

if [[ -z "${SERVICE_HTTP_DIRECTORY}" ]]; then
  echo "Missing SERVICE_HTTP_DIRECTORY in remote result file: ${RESULT_FILE}"
  exit 1
fi

if [[ -n "${APP_URL_PATH}" ]]; then
  APP_URL="http://127.0.0.1:${SERVICE_HTTP_PORT}${APP_URL_PATH}"
  WAIT_URL="${APP_URL}"
fi

echo "Configuring kiosk user service and Chromium launch"
PI_HOST="${PI_HOST}" \
PI_USER="${PI_USER}" \
PI_PORT="${PI_PORT}" \
SSH_OPTS="${SSH_OPTS}" \
APP_URL="${APP_URL}" \
WAIT_URL="${WAIT_URL}" \
SERVICE_HTTP_PORT="${SERVICE_HTTP_PORT}" \
SERVICE_HTTP_DIRECTORY="${SERVICE_HTTP_DIRECTORY}" \
FORCE="${FORCE}" \
bash "${SCRIPT_DIR}/setup-kiosk-user.sh"

if [[ "${RESTART_TTY_ON_UPDATE}" == "1" && "${INSTALL_WAS_UPDATE}" == "1" ]]; then
  echo "Detected app update; restarting getty@tty1 to refresh kiosk session"
  ssh -tt -p "${PI_PORT}" "${EXTRA_SSH_OPTS[@]}" "${TARGET}" "sudo systemctl restart getty@tty1.service || sudo systemctl restart getty@tty1"
fi

echo
echo "Install complete."
echo "App repo: ${APP_REPO}"
echo "Remote app dir: ${APP_REPO_DIR}"
echo "HTTP serve dir: ${SERVICE_HTTP_DIRECTORY}"
echo "Kiosk URL: ${APP_URL}"
echo "Was update: ${INSTALL_WAS_UPDATE}"
