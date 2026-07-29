#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly UPSTREAM_DIR="${ROOT_DIR}/web/slimenrf-ota-web"
readonly COMMAND_DIR="${ROOT_DIR}/web/slimenrf-remote-command"

log() {
    printf '[build-web] %s\n' "$*"
}

die() {
    printf '[build-web] error: %s\n' "$*" >&2
    exit 1
}

require_clean_upstream() {
    local status
    status="$(git -C "${UPSTREAM_DIR}" status --porcelain --untracked-files=all)"
    [[ -z "${status}" ]] || {
        printf '%s\n' "${status}" >&2
        die "slimenrf-ota-web must have a clean source worktree"
    }
}

command -v pnpm >/dev/null 2>&1 || die "pnpm is required"
[[ -f "${UPSTREAM_DIR}/package.json" ]] || die "slimenrf-ota-web is not initialized"
[[ -f "${COMMAND_DIR}/package.json" ]] || die "remote command module is missing"

require_clean_upstream

log "building the unmodified OTA upstream"
pnpm --dir "${UPSTREAM_DIR}" run build

log "testing the remote command module"
pnpm --dir "${COMMAND_DIR}" run test

log "building the remote command module"
pnpm --dir "${COMMAND_DIR}" run build

log "composing dist/commands and the generated navigation"
node "${SCRIPT_DIR}/compose-web.mjs"

require_clean_upstream

[[ -f "${UPSTREAM_DIR}/dist/index.html" ]] ||
    die "composed OTA index is missing"
[[ -f "${UPSTREAM_DIR}/dist/commands/index.html" ]] ||
    die "composed command page is missing"
grep -Fq '<!-- smol-remote-command-nav -->' "${UPSTREAM_DIR}/dist/index.html" ||
    die "generated navigation marker is missing"

log "composite site is ready at web/slimenrf-ota-web/dist"
