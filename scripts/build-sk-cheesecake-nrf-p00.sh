#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly APP_DIR="${ROOT_DIR}/tracker/SlimeVR-Tracker-nRF"
readonly APP_WORKSPACE_DIR="${ROOT_DIR}/tracker"
readonly BOOTLOADER_DIR="${ROOT_DIR}/boot/Adafruit_nRF52_Bootloader"
readonly BOOTLOADER_PYTHON="${ROOT_DIR}/.venv-bootloader/bin/python"
readonly BUILD_DIR="${ROOT_DIR}/build/sk_cheesecake_nrf_p00"
readonly APP_BUILD_DIR="${BUILD_DIR}/app"
readonly BOOTLOADER_BUILD_DIR="${BUILD_DIR}/bootloader"
readonly ARTIFACT_DIR="${ROOT_DIR}/artifacts/sk_cheesecake_nrf_p00"
readonly APP_BOARD="sk_cheesecake_nrf_p00/nrf52840/uf2"
readonly BOOTLOADER_BOARD="sk_cheesecake_nrf_p00"
readonly EXPECTED_NCS_SERIES="v3.2"

PRISTINE_MODE="auto"
WEST_COMMAND=""

usage() {
    cat <<'EOF'
Usage: ./scripts/build-sk-cheesecake-nrf-p00.sh [--pristine]

Build the sk_cheesecake_nrf_p00 tracker application and bootloader, then
collect the flashable HEX/UF2 files under artifacts/sk_cheesecake_nrf_p00.

The workspace, west projects, Python environments, and compiler toolchains
must already be initialized.

Options:
  --pristine   Force a clean CMake configure for the tracker application.
  -h, --help   Show this help.

Environment:
  NCS_TOOLCHAIN_ROOT  Explicit nRF Connect SDK Toolchain bundle directory.
  NCS_TOOLCHAINS_DIR Directory containing toolchains.json and toolchain bundles.
  CCACHE_DIR          Override the app compiler cache directory.
EOF
}

log() {
    printf '[build-sk-cheesecake-nrf-p00] %s\n' "$*"
}

die() {
    printf '[build-sk-cheesecake-nrf-p00] error: %s\n' "$*" >&2
    exit 1
}

on_error() {
    local exit_code="$1"
    local line="$2"
    local command="$3"

    printf \
        '[build-sk-cheesecake-nrf-p00] failed at line %s (exit %s): %s\n' \
        "${line}" \
        "${exit_code}" \
        "${command}" >&2
}

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "required command not found: $1"
}

while (($#)); do
    case "$1" in
        --pristine)
            PRISTINE_MODE="always"
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown argument: $1"
            ;;
    esac
    shift
done

discover_ncs_toolchain() {
    local host_python="$1"
    local toolchains_dir="$2"
    local registry="${toolchains_dir}/toolchains.json"

    [[ -f "${registry}" ]] || return 1

    "${host_python}" - "${registry}" "${toolchains_dir}" "${EXPECTED_NCS_SERIES}" <<'PY'
import json
import pathlib
import re
import sys

registry_path = pathlib.Path(sys.argv[1])
toolchains_dir = pathlib.Path(sys.argv[2])
expected_series = sys.argv[3]

with registry_path.open(encoding="utf-8") as registry_file:
    registries = json.load(registry_file)

candidates = []
for registry in registries:
    for toolchain in registry.get("toolchains", []):
        bundle_id = toolchain.get("identifier", {}).get("bundle_id")
        if not bundle_id:
            continue
        for version in toolchain.get("ncs_versions", []):
            if version == expected_series or version.startswith(expected_series + "."):
                version_key = tuple(
                    int(part) for part in re.findall(r"\d+", version)
                )
                bundle_dir = toolchains_dir / bundle_id
                if (bundle_dir / "environment.json").is_file():
                    candidates.append((version_key, bundle_dir))

if not candidates:
    raise SystemExit(1)

print(max(candidates, key=lambda item: item[0])[1])
PY
}

load_ncs_toolchain_environment() {
    local host_python="$1"
    local toolchain_root="$2"
    local environment_file="${toolchain_root}/environment.json"
    local environment_output
    local key
    local value

    [[ -f "${environment_file}" ]] ||
        die "NCS toolchain environment file not found: ${environment_file}"

    environment_output="$(
        "${host_python}" - "${environment_file}" "${toolchain_root}" <<'PY'
import json
import os
import pathlib
import re
import sys

environment_file = pathlib.Path(sys.argv[1])
toolchain_root = pathlib.Path(sys.argv[2])

with environment_file.open(encoding="utf-8") as source:
    environment = json.load(source)

for entry in environment.get("env_vars", []):
    key = entry["key"]
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
        raise SystemExit(f"invalid environment key: {key!r}")

    if entry["type"] == "relative_paths":
        values = [str(toolchain_root / value) for value in entry["values"]]
        treatment = entry.get("existing_value_treatment", "overwrite")
        if treatment == "prepend_to" and os.environ.get(key):
            values.append(os.environ[key])
        elif treatment not in {"prepend_to", "overwrite"}:
            raise SystemExit(
                f"unsupported existing value treatment for {key}: {treatment}"
            )
        value = os.pathsep.join(values)
    elif entry["type"] == "string":
        value = entry["value"]
    else:
        raise SystemExit(
            f"unsupported environment entry type for {key}: {entry['type']}"
        )

    if "\t" in value or "\n" in value:
        raise SystemExit(f"unsupported control character in value for {key}")
    print(f"{key}\t{value}")
PY
    )" || die "could not read NCS toolchain environment: ${environment_file}"

    while IFS=$'\t' read -r key value; do
        [[ -n "${key}" ]] || continue
        export "${key}=${value}"
    done <<<"${environment_output}"
}

prepare_ncs_toolchain() {
    local host_python
    local toolchain_root="${NCS_TOOLCHAIN_ROOT:-}"
    local toolchains_dir

    if [[ -z "${toolchain_root}" ]] &&
        command -v west >/dev/null 2>&1 &&
        [[ -n "${ZEPHYR_SDK_INSTALL_DIR:-}" ]] &&
        [[ -d "${ZEPHYR_SDK_INSTALL_DIR}" ]]; then
        WEST_COMMAND="$(command -v west)"
        log "using active NCS/Zephyr environment: ${WEST_COMMAND}"
        return
    fi

    host_python="$(command -v python3 || true)"
    [[ -n "${host_python}" ]] ||
        die "python3 is required to load an installed NCS toolchain"

    if [[ -z "${toolchain_root}" ]]; then
        [[ -n "${HOME:-}" ]] ||
            die "HOME is not set; set NCS_TOOLCHAIN_ROOT explicitly"
        toolchains_dir="${NCS_TOOLCHAINS_DIR:-${HOME}/ncs/toolchains}"
        toolchain_root="$(
            discover_ncs_toolchain "${host_python}" "${toolchains_dir}"
        )" || die \
            "no ${EXPECTED_NCS_SERIES}.x toolchain found; activate a compatible NCS toolchain or set NCS_TOOLCHAIN_ROOT"
    fi

    load_ncs_toolchain_environment "${host_python}" "${toolchain_root}"
    WEST_COMMAND="$(command -v west || true)"
    [[ -n "${WEST_COMMAND}" ]] ||
        die "west was not provided by NCS toolchain: ${toolchain_root}"

    log "loaded NCS toolchain: ${toolchain_root}"
}

require_initialized_workspace() {
    local west_topdir

    [[ -d "${APP_DIR}" ]] ||
        die "tracker source is missing; run ./scripts/bootstrap.sh first"
    [[ -d "${BOOTLOADER_DIR}" ]] ||
        die "bootloader source is missing; run ./scripts/bootstrap.sh first"
    [[ -d "${APP_WORKSPACE_DIR}/.west" ]] ||
        die "tracker west workspace is missing; run ./scripts/bootstrap.sh first"
    [[ -f "${APP_WORKSPACE_DIR}/zephyr/CMakeLists.txt" ]] ||
        die "tracker west projects are incomplete; run ./scripts/bootstrap.sh"
    [[ -d "${APP_DIR}/boards/crazt/sk_cheesecake_nrf_p00" ]] ||
        die "tracker board definition is missing: ${APP_BOARD}"
    [[ -d "${BOOTLOADER_DIR}/src/boards/sk_cheesecake_nrf_p00" ]] ||
        die "bootloader board definition is missing: ${BOOTLOADER_BOARD}"
    [[ -x "${BOOTLOADER_PYTHON}" ]] ||
        die "bootloader Python environment is missing; run ./scripts/bootstrap.sh"

    (
        unset PYTHONHOME PYTHONPATH
        "${BOOTLOADER_PYTHON}" -c 'import intelhex'
    ) || die "intelhex is missing from ${BOOTLOADER_PYTHON}"

    west_topdir="$(
        cd "${APP_DIR}"
        "${WEST_COMMAND}" topdir
    )"
    [[ "${west_topdir}" == "${APP_WORKSPACE_DIR}" ]] ||
        die "unexpected tracker west top directory: ${west_topdir}"
}

build_application() {
    local ccache_dir="${CCACHE_DIR:-${BUILD_DIR}/.ccache}"

    mkdir -p "${ccache_dir}"
    log "building tracker application (${APP_BOARD}, pristine=${PRISTINE_MODE})"
    (
        cd "${APP_DIR}"
        CCACHE_DIR="${ccache_dir}" "${WEST_COMMAND}" build \
            --board "${APP_BOARD}" \
            --pristine="${PRISTINE_MODE}" \
            "${APP_DIR}" \
            --build-dir "${APP_BUILD_DIR}" \
            -- \
            -DBOARD_ROOT="${APP_DIR}"
    )
}

build_bootloader() {
    log "building bootloader (${BOOTLOADER_BOARD})"
    (
        cd "${BOOTLOADER_DIR}"
        env -u PYTHONHOME -u PYTHONPATH \
            cmake \
            -S . \
            -B "${BOOTLOADER_BUILD_DIR}" \
            -G Ninja \
            -DBOARD="${BOOTLOADER_BOARD}" \
            -DPython_EXECUTABLE="${BOOTLOADER_PYTHON}" \
            -DCMAKE_BUILD_TYPE=MinSizeRel

        env -u PYTHONHOME -u PYTHONPATH \
            cmake \
            --build "${BOOTLOADER_BUILD_DIR}" \
            --parallel
    )
}

collect_artifacts() {
    local app_image_dir="${APP_BUILD_DIR}/SlimeVR-Tracker-nRF/zephyr"
    local source
    local required_sources=(
        "${app_image_dir}/zephyr.uf2"
        "${app_image_dir}/zephyr.hex"
        "${APP_BUILD_DIR}/merged.hex"
        "${BOOTLOADER_BUILD_DIR}/bootloader_mbr.uf2"
        "${BOOTLOADER_BUILD_DIR}/bootloader_mbr.hex"
    )
    local artifact_names=(
        "app.uf2"
        "app.hex"
        "app-merged.hex"
        "bootloader_mbr.uf2"
        "bootloader_mbr.hex"
    )
    local index

    for source in "${required_sources[@]}"; do
        [[ -s "${source}" ]] || die "expected build artifact is missing: ${source}"
    done

    mkdir -p "${ARTIFACT_DIR}"
    for index in "${!required_sources[@]}"; do
        cp -- \
            "${required_sources[index]}" \
            "${ARTIFACT_DIR}/${artifact_names[index]}"
    done

    (
        cd "${ARTIFACT_DIR}"
        sha256sum "${artifact_names[@]}" >SHA256SUMS
    )

    log "artifacts:"
    (
        cd "${ROOT_DIR}"
        du -h \
            "artifacts/sk_cheesecake_nrf_p00/app.uf2" \
            "artifacts/sk_cheesecake_nrf_p00/app.hex" \
            "artifacts/sk_cheesecake_nrf_p00/app-merged.hex" \
            "artifacts/sk_cheesecake_nrf_p00/bootloader_mbr.uf2" \
            "artifacts/sk_cheesecake_nrf_p00/bootloader_mbr.hex"
    )
}

prepare_ncs_toolchain
require_command git
require_command cmake
require_command ninja
require_command arm-none-eabi-gcc
require_command sha256sum
require_initialized_workspace
build_application
build_bootloader
collect_artifacts

log "build complete: ${ARTIFACT_DIR}"
