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
readonly MERGEHEX_SCRIPT="${APP_WORKSPACE_DIR}/zephyr/scripts/build/mergehex.py"
readonly APP_UF2="${BUILD_DIR}/app.uf2"
readonly BOOTLOADER_UF2="${BUILD_DIR}/bootloader_mbr.uf2"
readonly FACTORY_HEX="${BUILD_DIR}/sk_cheesecake_nrf_p00_factory_test.hex"
readonly CHECKSUM_FILE="${BUILD_DIR}/SHA256SUMS"
readonly APP_BOARD="sk_cheesecake_nrf_p00/nrf52840/uf2"
readonly BOOTLOADER_BOARD="sk_cheesecake_nrf_p00"
readonly EXPECTED_NCS_SERIES="v3.2"

PRISTINE_MODE="auto"
WEST_COMMAND=""

usage() {
    cat <<'EOF'
Usage: ./scripts/build-sk-cheesecake-nrf-p00.sh [--pristine]

Build the sk_cheesecake_nrf_p00 tracker application and bootloader, then
place the app UF2, bootloader UF2, and merged factory HEX directly under
build/sk_cheesecake_nrf_p00.

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
    [[ -f "${MERGEHEX_SCRIPT}" ]] ||
        die "Zephyr mergehex tool is missing: ${MERGEHEX_SCRIPT}"
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

validate_factory_firmware() {
    local bootloader_hex="$1"
    local app_hex="$2"
    local factory_hex="$3"

    env -u PYTHONHOME -u PYTHONPATH \
        "${BOOTLOADER_PYTHON}" \
        - "${bootloader_hex}" "${app_hex}" "${factory_hex}" <<'PY'
from intelhex import IntelHex
import sys

boot = IntelHex(sys.argv[1])
app = IntelHex(sys.argv[2])
factory = IntelHex(sys.argv[3])

boot_addrs = set(boot.addresses())
app_addrs = set(app.addresses())
factory_addrs = set(factory.addresses())

assert boot_addrs, "Bootloader HEX 没有数据"
assert app_addrs, "App HEX 没有数据"
assert boot_addrs.isdisjoint(app_addrs), "Bootloader 和 App 地址重叠"
assert factory_addrs == boot_addrs | app_addrs, "输出地址集合不是输入并集"
assert all(factory[address] == boot[address] for address in boot_addrs), (
    "Bootloader 数据被改变"
)
assert all(factory[address] == app[address] for address in app_addrs), (
    "App 数据被改变"
)

app_first = min(app_addrs)
app_last = max(app_addrs)
assert app_first == 0x1000, hex(app_first)
assert app_last < 0xE0000, hex(app_last)

stack_pointer = int.from_bytes(
    bytes(app[address] for address in range(0x1000, 0x1004)), "little"
)
reset_handler = int.from_bytes(
    bytes(app[address] for address in range(0x1004, 0x1008)), "little"
)
assert 0x20000000 <= stack_pointer < 0x20040000, hex(stack_pointer)
assert reset_handler & 1, hex(reset_handler)
assert app_first <= (reset_handler & ~1) <= app_last, hex(reset_handler)

assert 0xF4000 in boot_addrs, "Bootloader 未从 0xF4000 开始"
boot_address = int.from_bytes(
    bytes(factory[address] for address in range(0x10001014, 0x10001018)),
    "little",
)
mbr_parameter_address = int.from_bytes(
    bytes(factory[address] for address in range(0x10001018, 0x1000101C)),
    "little",
)
assert boot_address == 0xF4000, hex(boot_address)
assert mbr_parameter_address == 0xFE000, hex(mbr_parameter_address)

assert not any(
    0xE0000 <= address < 0xEA000 for address in factory_addrs
), "BL 暂存区非空"
assert not any(
    0xEE000 <= address < 0xF4000 for address in factory_addrs
), "NVS 非空"
assert not any(
    0xFE000 <= address < 0xFF000 for address in factory_addrs
), "MBR 参数页非空"
assert not any(
    0xFF000 <= address < 0x100000 for address in factory_addrs
), "settings 页非空"

print("Boot segments:", [(hex(start), hex(end)) for start, end in boot.segments()])
print("App segments:", [(hex(start), hex(end)) for start, end in app.segments()])
print(
    "Factory segments:",
    [(hex(start), hex(end)) for start, end in factory.segments()],
)
print(
    f"App vector: SP=0x{stack_pointer:08X}, "
    f"reset=0x{reset_handler:08X}"
)
print(
    f"UICR: boot=0x{boot_address:X}, "
    f"mbr_params=0x{mbr_parameter_address:X}"
)
print("ALL STATIC CHECKS PASSED")
PY
}

stage_firmware_outputs() {
    local app_image_dir="${APP_BUILD_DIR}/SlimeVR-Tracker-nRF/zephyr"
    local app_source_uf2="${app_image_dir}/zephyr.uf2"
    local app_source_hex="${app_image_dir}/zephyr.hex"
    local bootloader_source_uf2="${BOOTLOADER_BUILD_DIR}/bootloader_mbr.uf2"
    local bootloader_source_hex="${BOOTLOADER_BUILD_DIR}/bootloader_mbr.hex"
    local factory_temp
    local source
    local required_sources=(
        "${app_source_uf2}"
        "${app_source_hex}"
        "${bootloader_source_uf2}"
        "${bootloader_source_hex}"
    )

    for source in "${required_sources[@]}"; do
        [[ -s "${source}" ]] ||
            die "expected build artifact is missing: ${source}"
    done

    factory_temp="$(mktemp "${BUILD_DIR}/.factory.XXXXXXXX.hex")"
    if ! env -u PYTHONHOME -u PYTHONPATH \
        "${BOOTLOADER_PYTHON}" \
        "${MERGEHEX_SCRIPT}" \
        --overlap=error \
        -o "${factory_temp}" \
        "${bootloader_source_hex}" \
        "${app_source_hex}"; then
        rm -f -- "${factory_temp}"
        die "factory firmware merge failed"
    fi

    if ! validate_factory_firmware \
        "${bootloader_source_hex}" \
        "${app_source_hex}" \
        "${factory_temp}"; then
        rm -f -- "${factory_temp}"
        die "factory firmware static validation failed"
    fi

    cp -- "${app_source_uf2}" "${APP_UF2}"
    cp -- "${bootloader_source_uf2}" "${BOOTLOADER_UF2}"
    mv -f -- "${factory_temp}" "${FACTORY_HEX}"

    (
        cd "${BUILD_DIR}"
        sha256sum \
            "${APP_UF2##*/}" \
            "${BOOTLOADER_UF2##*/}" \
            "${FACTORY_HEX##*/}" \
            >"${CHECKSUM_FILE##*/}"
    )

    log "firmware outputs:"
    (
        cd "${BUILD_DIR}"
        du -h \
            "${APP_UF2##*/}" \
            "${BOOTLOADER_UF2##*/}" \
            "${FACTORY_HEX##*/}" \
            "${CHECKSUM_FILE##*/}"
    )
}

prepare_ncs_toolchain
require_command git
require_command cmake
require_command ninja
require_command arm-none-eabi-gcc
require_command sha256sum
require_command mktemp
require_initialized_workspace
build_application
build_bootloader
stage_firmware_outputs

log "build complete: ${BUILD_DIR}"
