#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly WEST_VENV_DIR="${ROOT_DIR}/.venv-west"
readonly BOOTLOADER_VENV_DIR="${ROOT_DIR}/.venv-bootloader"

UPDATE_SDK=1

usage() {
    cat <<'EOF'
Usage: ./scripts/bootstrap.sh [--init-only]

Initialize all Git submodules, the west and bootloader Python environments,
and both west workspaces. By default, SDK repositories are also downloaded
or updated.

Options:
  --init-only  Initialize west metadata without downloading/updating SDK repos.
  -h, --help   Show this help.
EOF
}

log() {
    printf '[bootstrap] %s\n' "$*"
}

die() {
    printf '[bootstrap] error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

while (($#)); do
    case "$1" in
        --init-only)
            UPDATE_SDK=0
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

require_command git
require_command python3

cd "${ROOT_DIR}"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "${ROOT_DIR} is not a Git working tree"

log "synchronizing top-level submodule URLs"
git submodule sync

log "initializing source repositories"
git submodule update --init \
    boot/Adafruit_nRF52_Bootloader \
    recv/SlimeVR-Tracker-nRF-Receiver \
    tracker/SlimeVR-Tracker-nRF \
    web/slimenrf-ota-web \
    web/slimenrf-remote-command

log "initializing direct bootloader dependencies"
git -C boot/Adafruit_nRF52_Bootloader submodule sync
git -C boot/Adafruit_nRF52_Bootloader submodule update --init

log "initializing tracker dependencies recursively"
git -C tracker/SlimeVR-Tracker-nRF submodule sync --recursive
git -C tracker/SlimeVR-Tracker-nRF submodule update --init --recursive

if [[ ! -x "${WEST_VENV_DIR}/bin/python" ]]; then
    log "creating west Python virtual environment"
    python3 -m venv "${WEST_VENV_DIR}"
fi

log "installing west workspace tools"
"${WEST_VENV_DIR}/bin/python" -m pip install \
    --disable-pip-version-check \
    --requirement "${ROOT_DIR}/requirements-west.txt"

if [[ ! -x "${BOOTLOADER_VENV_DIR}/bin/python" ]]; then
    log "creating bootloader Python virtual environment"
    python3 -m venv "${BOOTLOADER_VENV_DIR}"
fi

log "installing bootloader Python tools"
"${BOOTLOADER_VENV_DIR}/bin/python" -m pip install \
    --disable-pip-version-check \
    --requirement "${ROOT_DIR}/requirements-bootloader.txt"

readonly WEST="${WEST_VENV_DIR}/bin/west"

init_west_workspace() {
    local workspace_dir="$1"
    local manifest_dir="$2"
    local actual_topdir

    if [[ ! -d "${workspace_dir}/.west" ]]; then
        log "initializing west workspace: ${workspace_dir#${ROOT_DIR}/}"
        (
            cd "${manifest_dir}"
            "${WEST}" init -l .
        )
    fi

    actual_topdir="$(
        cd "${manifest_dir}"
        "${WEST}" topdir
    )"
    [[ "${actual_topdir}" == "${workspace_dir}" ]] ||
        die "unexpected west top directory for ${manifest_dir}: ${actual_topdir}"

    if ((UPDATE_SDK)); then
        log "updating west workspace: ${workspace_dir#${ROOT_DIR}/}"
        (
            cd "${manifest_dir}"
            "${WEST}" update
        )
    fi
}

init_west_workspace \
    "${ROOT_DIR}/recv" \
    "${ROOT_DIR}/recv/SlimeVR-Tracker-nRF-Receiver"

init_west_workspace \
    "${ROOT_DIR}/tracker" \
    "${ROOT_DIR}/tracker/SlimeVR-Tracker-nRF"

if ((UPDATE_SDK)); then
    log "workspace initialization complete"
else
    log "workspace metadata initialized; run this script without --init-only to download SDK repositories"
fi

log "activate west tools with: source .venv-west/bin/activate"
log "bootloader Python: .venv-bootloader/bin/python"
