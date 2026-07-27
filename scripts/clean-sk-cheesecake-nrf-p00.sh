#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly TARGETS=(
    "${ROOT_DIR}/build"
    "${ROOT_DIR}/artifacts"
)

DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: ./scripts/clean-sk-cheesecake-nrf-p00.sh [--dry-run]

Remove all top-level build outputs and collected artifacts.

Options:
  --dry-run    Show the directories that would be removed without deleting them.
  -h, --help   Show this help.

This script removes the entire build/ and artifacts/ directories. It does not
remove source repositories, west projects, or Python environments.
EOF
}

log() {
    printf '[clean-sk-cheesecake-nrf-p00] %s\n' "$*"
}

die() {
    printf '[clean-sk-cheesecake-nrf-p00] error: %s\n' "$*" >&2
    exit 1
}

while (($#)); do
    case "$1" in
        --dry-run)
            DRY_RUN=1
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

require_repository_root() {
    local actual_root

    actual_root="$(git -C "${ROOT_DIR}" rev-parse --show-toplevel 2>/dev/null)" ||
        die "${ROOT_DIR} is not a Git working tree"
    [[ "${actual_root}" == "${ROOT_DIR}" ]] ||
        die "unexpected Git repository root: ${actual_root}"
}

require_safe_target() {
    local target="$1"

    case "${target}" in
        "${ROOT_DIR}/build" | \
        "${ROOT_DIR}/artifacts")
            ;;
        *)
            die "refusing to remove unexpected path: ${target}"
            ;;
    esac
}

remove_target() {
    local target="$1"
    local display_path="${target#${ROOT_DIR}/}"

    require_safe_target "${target}"

    if [[ ! -e "${target}" && ! -L "${target}" ]]; then
        log "not present: ${display_path}"
        return
    fi

    if ((DRY_RUN)); then
        log "would remove: ${display_path}"
    else
        log "removing: ${display_path}"
        rm -rf -- "${target}"
    fi
}

require_repository_root

for target in "${TARGETS[@]}"; do
    remove_target "${target}"
done

if ((DRY_RUN)); then
    log "dry run complete; nothing was removed"
else
    log "clean complete; generated files can be restored by running the build script"
fi
