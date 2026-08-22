#!/usr/bin/env bash
# Build firmware targets from build.yaml inside the Dev Container.
#
# Usage:
#   ./scripts/build.sh              # incremental build of every target
#   ./scripts/build.sh -p           # pristine rebuild
#   ./scripts/build.sh list         # show targets
#   ./scripts/build.sh update       # re-fetch west modules
#   ./scripts/build.sh sessile_central
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZMK_WS="${ZMK_WORKSPACE:-/zmk}"
BUILD_YAML="${BUILD_CONFIG:-${REPO_ROOT}/build.yaml}"
OUT_DIR="${REPO_ROOT}/out"
PRISTINE=false

# Zephyr 4.1 board IDs (see zmk.dev blog: Zephyr 4.1 Update).
normalize_board() {
  case "$1" in
    seeeduino_xiao_ble) printf '%s' 'xiao_ble//zmk' ;;
    seeeduino_xiao_rp2040) printf '%s' 'xiao_rp2040//zmk' ;;
    nice_nano_v2) printf '%s' 'nice_nano//zmk' ;;
    *) printf '%s' "$1" ;;
  esac
}

setup_toolchain() {
  export ZEPHYR_BASE="${ZEPHYR_BASE:-${ZMK_WS}/zephyr}"
  if [ -z "${ZEPHYR_SDK_INSTALL_DIR:-}" ]; then
    if [ -n "${ZEPHYR_SDK_VERSION:-}" ] && [ -d "/opt/zephyr-sdk-${ZEPHYR_SDK_VERSION}" ]; then
      export ZEPHYR_SDK_INSTALL_DIR="/opt/zephyr-sdk-${ZEPHYR_SDK_VERSION}"
    else
      local sdk
      for sdk in /opt/zephyr-sdk-*; do
        if [ -d "${sdk}" ]; then
          export ZEPHYR_SDK_INSTALL_DIR="${sdk}"
          break
        fi
      done
    fi
  fi
  local host_tools="${ZEPHYR_SDK_INSTALL_DIR:-}/sysroots/x86_64-pokysdk-linux/usr/bin"
  if [ -d "${host_tools}" ]; then
    case ":${PATH}:" in
      *":${host_tools}:"*) ;;
      *) export PATH="${host_tools}:${PATH}" ;;
    esac
  fi
}

usage() {
  cat <<EOF
Usage: $0 [options] [target ...]

Options:
  -p        Pristine build (rebuild from scratch)
  -h        Show this help

Commands:
  list      Print artifact names from build.yaml
  update    Run west update in the container workspace

If no target is given, every uncommented entry in build.yaml is built.
Firmware is copied to ${OUT_DIR}/
EOF
}

trim() {
  local val="$1"
  val="${val%%\#*}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "$val"
}

parse_build_yaml() {
  if [ ! -f "${BUILD_YAML}" ]; then
    echo "error: ${BUILD_YAML} not found" >&2
    exit 1
  fi

  local in_include=0
  local board="" shield="" snippet="" cmake_args="" artifact=""

  emit() {
    if [ -n "${board}" ]; then
      local name="${artifact}"
      if [ -z "${name}" ]; then
        name="${board}"
        [ -n "${shield}" ] && name="${shield}-${board}"
      fi
      printf '%s|%s|%s|%s|%s\n' "${board}" "${shield}" "${snippet}" "${cmake_args}" "${name}"
    fi
    board=""
    shield=""
    snippet=""
    cmake_args=""
    artifact=""
  }

  while IFS= read -r line || [ -n "${line}" ]; do
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue

    if [[ "${line}" =~ ^include: ]]; then
      in_include=1
      continue
    fi

    if [ "${in_include}" -eq 1 ]; then
      if [[ "${line}" =~ ^[[:space:]]*-[[:space:]]*board:[[:space:]]*(.*) ]]; then
        emit
        board="$(trim "${BASH_REMATCH[1]}")"
      elif [[ "${line}" =~ ^[[:space:]]+shield:[[:space:]]*(.*) ]]; then
        shield="$(trim "${BASH_REMATCH[1]}")"
      elif [[ "${line}" =~ ^[[:space:]]+snippet:[[:space:]]*(.*) ]]; then
        snippet="$(trim "${BASH_REMATCH[1]}")"
      elif [[ "${line}" =~ ^[[:space:]]+cmake-args:[[:space:]]*(.*) ]]; then
        cmake_args="$(trim "${BASH_REMATCH[1]}")"
      elif [[ "${line}" =~ ^[[:space:]]+artifact-name:[[:space:]]*(.*) ]]; then
        artifact="$(trim "${BASH_REMATCH[1]}")"
      fi
    fi
  done < "${BUILD_YAML}"
  emit
}

ensure_workspace() {
  if [ ! -f "${ZMK_WS}/.west/config" ]; then
    echo "error: west workspace not found at ${ZMK_WS}." >&2
    echo "Open this repo in the Dev Container so setup can initialize it." >&2
    exit 1
  fi
  ln -sfn "${REPO_ROOT}/config" "${ZMK_WS}/config"
  setup_toolchain
  cd "${ZMK_WS}"
}

build_one() {
  local board="$1" shield="$2" snippet="$3" cmake_args="$4" artifact="$5"
  board="$(normalize_board "${board}")"
  local build_dir="${ZMK_WS}/build/${artifact}"
  local cmd=(west build -s zmk/app -d "${build_dir}" -b "${board}")
  local need_pristine="${PRISTINE}"

  if [ "${need_pristine}" != true ] && [ -f "${build_dir}/CMakeCache.txt" ]; then
    local cached_board=""
    cached_board="$(awk -F= '/^BOARD:STRING=/{print $2}' "${build_dir}/CMakeCache.txt")"
    if [ -n "${cached_board}" ] && [ "${cached_board}" != "${board}" ] && [ "${cached_board}" != "${board%%//*}" ]; then
      echo "    cached board ${cached_board} != ${board}; doing a pristine build"
      need_pristine=true
    fi
  fi

  if [ "${need_pristine}" = true ]; then
    cmd+=(-p)
  fi
  if [ -n "${snippet}" ]; then
    cmd+=(-S "${snippet}")
  fi

  cmd+=(-- "-DZMK_CONFIG=${ZMK_WS}/config" "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON")
  if [ -n "${shield}" ]; then
    cmd+=("-DSHIELD=${shield}")
  fi
  if [ -n "${cmake_args}" ]; then
    # shellcheck disable=SC2206
    local extra=(${cmake_args})
    cmd+=("${extra[@]}")
  fi

  echo "==> Building ${artifact} (board=${board}${shield:+ shield=${shield}})"
  "${cmd[@]}"

  mkdir -p "${OUT_DIR}"
  if [ -f "${build_dir}/zephyr/zmk.uf2" ]; then
    cp "${build_dir}/zephyr/zmk.uf2" "${OUT_DIR}/${artifact}.uf2"
    echo "    ${OUT_DIR}/${artifact}.uf2"
  elif [ -f "${build_dir}/zephyr/zmk.bin" ]; then
    cp "${build_dir}/zephyr/zmk.bin" "${OUT_DIR}/${artifact}.bin"
    echo "    ${OUT_DIR}/${artifact}.bin"
  else
    echo "error: no zmk.uf2 or zmk.bin produced for ${artifact}" >&2
    return 1
  fi
}

cmd="${1:-}"
if [ "${cmd}" = "-h" ] || [ "${cmd}" = "--help" ]; then
  usage
  exit 0
fi

if [ "${cmd}" = "list" ]; then
  while IFS='|' read -r board shield snippet cmake_args artifact; do
    printf '%-24s board=%s' "${artifact}" "$(normalize_board "${board}")"
    [ -n "${shield}" ] && printf ' shield=%s' "${shield}"
    [ -n "${snippet}" ] && printf ' snippet=%s' "${snippet}"
    printf '\n'
  done < <(parse_build_yaml)
  exit 0
fi

if [ "${cmd}" = "update" ]; then
  ensure_workspace
  west update --fetch-opt=--filter=tree:0
  west zephyr-export
  sha256sum "${ZMK_WS}/config/west.yml" | awk '{print $1}' > "${ZMK_WS}/.west-yml.sha256"
  echo "West modules updated."
  exit 0
fi

targets=()
while [ $# -gt 0 ]; do
  case "$1" in
    -p) PRISTINE=true ;;
    -h|--help) usage; exit 0 ;;
    *) targets+=("$1") ;;
  esac
  shift
done

ensure_workspace

built=0
while IFS='|' read -r board shield snippet cmake_args artifact; do
  if [ ${#targets[@]} -eq 0 ]; then
    build_one "${board}" "${shield}" "${snippet}" "${cmake_args}" "${artifact}"
    built=$((built + 1))
  else
    for t in "${targets[@]}"; do
      if [ "${t}" = "${artifact}" ]; then
        build_one "${board}" "${shield}" "${snippet}" "${cmake_args}" "${artifact}"
        built=$((built + 1))
      fi
    done
  fi
done < <(parse_build_yaml)

if [ "${built}" -eq 0 ]; then
  echo "error: no matching targets in ${BUILD_YAML}" >&2
  echo "Available:" >&2
  "$0" list >&2
  exit 1
fi

echo "Done. ${built} firmware image(s) in ${OUT_DIR}/"
