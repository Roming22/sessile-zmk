#!/usr/bin/env bash
# Initialize the west workspace inside the Dev Container.
# Zephyr, ZMK, and modules live in the /zmk Docker volume so they are not
# written into the git repo (and stay off a NAS bind-mount).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZMK_WS="${ZMK_WORKSPACE:-/zmk}"
CONFIG_LINK="${ZMK_WS}/config"
HASH_FILE="${ZMK_WS}/.west-yml.sha256"

mkdir -p "${ZMK_WS}"
ln -sfn "${REPO_ROOT}/config" "${CONFIG_LINK}"

if [ ! -f "${CONFIG_LINK}/west.yml" ]; then
  echo "error: ${CONFIG_LINK}/west.yml not found" >&2
  exit 1
fi

# west init -l resolves symlinks and creates .west next to the real
# config directory (the git repo). Keep the workspace on the /zmk volume.
if [ -d "${REPO_ROOT}/.west" ]; then
  echo "Removing leftover ${REPO_ROOT}/.west (west workspace is ${ZMK_WS})"
  rm -rf "${REPO_ROOT}/.west"
fi

git config --global --add safe.directory "${REPO_ROOT}" >/dev/null 2>&1 || true
git config --global --add safe.directory '*' >/dev/null 2>&1 || true

cd "${ZMK_WS}"

if [ ! -f "${ZMK_WS}/.west/config" ]; then
  echo "Initializing west workspace at ${ZMK_WS} ..."
  mkdir -p "${ZMK_WS}/.west"
  cat > "${ZMK_WS}/.west/config" <<EOF
[manifest]
path = config
file = west.yml
EOF
fi

CURRENT_HASH="$(sha256sum "${CONFIG_LINK}/west.yml" | awk '{print $1}')"
if [ ! -f "${HASH_FILE}" ] || [ "$(cat "${HASH_FILE}")" != "${CURRENT_HASH}" ]; then
  echo "Updating west modules (first run can take several minutes) ..."
  west update --fetch-opt=--filter=tree:0
  echo "${CURRENT_HASH}" > "${HASH_FILE}"
else
  echo "West modules already match config/west.yml."
fi

west zephyr-export

if command -v pip3 >/dev/null 2>&1; then
  echo "Installing Zephyr Python packages ..."
  PIP_BREAK_SYSTEM_PACKAGES=1 west packages pip --install --ignore-venv-check \
    || echo "warning: west packages pip --install failed; builds may miss Python deps" >&2
fi

west config --local build.cmake-args -- "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON" >/dev/null

if [ -z "${ZEPHYR_SDK_INSTALL_DIR:-}" ]; then
  if [ -n "${ZEPHYR_SDK_VERSION:-}" ] && [ -d "/opt/zephyr-sdk-${ZEPHYR_SDK_VERSION}" ]; then
    ZEPHYR_SDK_INSTALL_DIR="/opt/zephyr-sdk-${ZEPHYR_SDK_VERSION}"
  else
    for sdk in /opt/zephyr-sdk-*; do
      if [ -d "${sdk}" ]; then
        ZEPHYR_SDK_INSTALL_DIR="${sdk}"
        break
      fi
    done
  fi
fi

MARKER="# sessile-zmk-devcontainer"
if [ -f "${HOME}/.bashrc" ] && ! grep -q "${MARKER}" "${HOME}/.bashrc"; then
  cat >> "${HOME}/.bashrc" <<EOF

${MARKER}
export ZMK_WORKSPACE="${ZMK_WS}"
export ZMK_CONFIG="${CONFIG_LINK}"
export ZEPHYR_BASE="${ZMK_WS}/zephyr"
${ZEPHYR_SDK_INSTALL_DIR:+export ZEPHYR_SDK_INSTALL_DIR="${ZEPHYR_SDK_INSTALL_DIR}"}
alias zmk-build='${REPO_ROOT}/scripts/build.sh'
if [ -f "${ZMK_WS}/zephyr/zephyr-env.sh" ]; then
  # shellcheck disable=SC1091
  . "${ZMK_WS}/zephyr/zephyr-env.sh"
fi
if [ -d "\${ZEPHYR_SDK_INSTALL_DIR}/sysroots/x86_64-pokysdk-linux/usr/bin" ]; then
  PATH="\${ZEPHYR_SDK_INSTALL_DIR}/sysroots/x86_64-pokysdk-linux/usr/bin:\${PATH}"
fi
EOF
fi

echo
echo "West workspace ready."
echo "  Build firmware:  ./scripts/build.sh"
echo "  Pristine build:  ./scripts/build.sh -p"
echo "  List targets:    ./scripts/build.sh list"
echo "  UF2 output:      ${REPO_ROOT}/out/"
