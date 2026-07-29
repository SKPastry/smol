#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly SOURCE_PATHS=(
    "boot/Adafruit_nRF52_Bootloader"
    "recv/SlimeVR-Tracker-nRF-Receiver"
    "tracker/SlimeVR-Tracker-nRF"
    "web/slimenrf-ota-web"
    "web/slimenrf-remote-command"
)

log() {
    printf '[update-sources] %s\n' "$*"
}

die() {
    printf '[update-sources] error: %s\n' "$*" >&2
    exit 1
}

on_error() {
    local exit_code="$1"
    local line="$2"
    local command="$3"

    printf \
        '[update-sources] failed at line %s (exit %s): %s\n' \
        "${line}" \
        "${exit_code}" \
        "${command}" >&2
}

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

usage() {
    cat <<'EOF'
Usage: ./scripts/update-sources.sh

Fast-forward the five top-level source submodules to the remote branches
configured in .gitmodules, then synchronize their nested submodules.
EOF
}

if (($#)); then
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown argument: $1"
            ;;
    esac
fi

require_parent_files_clean() {
    local status
    local path
    local pathspecs=(.)

    for path in "${SOURCE_PATHS[@]}"; do
        pathspecs+=(":(exclude)${path}")
    done

    status="$(
        git -C "${ROOT_DIR}" status \
            --porcelain \
            --untracked-files=all \
            -- \
            "${pathspecs[@]}"
    )"

    [[ -z "${status}" ]] || {
        printf '%s\n' "${status}" >&2
        die "parent repository has changes outside the managed submodule paths"
    }
}

require_clean_worktree() {
    local repository="$1"
    local label="$2"
    local status

    status="$(git -C "${repository}" status --porcelain --untracked-files=all)"
    [[ -z "${status}" ]] || {
        printf '%s\n' "${status}" >&2
        die "${label} has uncommitted or untracked changes"
    }
}

configured_branch() {
    local path="$1"
    local branch

    branch="$(
        git -C "${ROOT_DIR}" config \
            --file .gitmodules \
            --get "submodule.${path}.branch"
    )" || die "no tracking branch configured for ${path} in .gitmodules"

    [[ -n "${branch}" && "${branch}" != "." ]] ||
        die "unsupported tracking branch for ${path}: ${branch:-<empty>}"

    printf '%s\n' "${branch}"
}

recorded_commit() {
    local path="$1"
    local metadata
    local mode
    local commit
    local stage
    local recorded_path

    metadata="$(git -C "${ROOT_DIR}" ls-files --stage -- "${path}")"
    read -r mode commit stage recorded_path <<<"${metadata}"

    [[ "${mode}" == "160000" && "${stage}" == "0" ]] ||
        die "${path} is not a recorded Git submodule"

    printf '%s\n' "${commit}"
}

initialize_source_if_missing() {
    local path="$1"
    local repository="${ROOT_DIR}/${path}"

    if ! git -C "${repository}" rev-parse --is-inside-work-tree \
        >/dev/null 2>&1; then
        log "initializing ${path}"
        git -C "${ROOT_DIR}" submodule update --init "${path}"
    fi
}

update_source() {
    local path="$1"
    local repository="${ROOT_DIR}/${path}"
    local branch
    local current_branch
    local current_commit
    local expected_commit
    local local_ref
    local remote_ref
    local local_commit
    local remote_commit

    branch="$(configured_branch "${path}")"
    require_clean_worktree "${repository}" "${path}"

    current_branch="$(git -C "${repository}" branch --show-current)"
    current_commit="$(git -C "${repository}" rev-parse HEAD)"
    expected_commit="$(recorded_commit "${path}")"

    if [[ -n "${current_branch}" && "${current_branch}" != "${branch}" ]]; then
        die "${path} is on branch ${current_branch}; finish that work before updating ${branch}"
    fi

    if [[ -z "${current_branch}" && "${current_commit}" != "${expected_commit}" ]]; then
        die "${path} has a detached commit not recorded by the parent repository"
    fi

    log "fetching ${path}: origin/${branch}"
    git -C "${repository}" fetch \
        --prune \
        origin \
        "refs/heads/${branch}:refs/remotes/origin/${branch}"

    local_ref="refs/heads/${branch}"
    remote_ref="refs/remotes/origin/${branch}"
    git -C "${repository}" show-ref --verify --quiet "${remote_ref}" ||
        die "remote branch not found for ${path}: origin/${branch}"

    remote_commit="$(git -C "${repository}" rev-parse "${remote_ref}")"

    if git -C "${repository}" show-ref --verify --quiet "${local_ref}"; then
        local_commit="$(git -C "${repository}" rev-parse "${local_ref}")"

        if [[ "${local_commit}" != "${remote_commit}" ]]; then
            if git -C "${repository}" merge-base \
                --is-ancestor "${local_commit}" "${remote_commit}"; then
                :
            elif git -C "${repository}" merge-base \
                --is-ancestor "${remote_commit}" "${local_commit}"; then
                die "${path} branch ${branch} contains commits not present on origin"
            else
                die "${path} branch ${branch} has diverged from origin/${branch}"
            fi
        fi

        git -C "${repository}" switch "${branch}"
        git -C "${repository}" merge --ff-only "${remote_ref}"
    else
        git -C "${repository}" switch \
            --create "${branch}" \
            --track "origin/${branch}"
    fi

    current_commit="$(git -C "${repository}" rev-parse HEAD)"
    [[ "${current_commit}" == "${remote_commit}" ]] ||
        die "${path} did not reach origin/${branch}"

    log "${path}: ${expected_commit:0:12} -> ${current_commit:0:12} (${branch})"
}

sync_nested_submodules() {
    local path="$1"
    local recursion="$2"
    local repository="${ROOT_DIR}/${path}"

    [[ -f "${repository}/.gitmodules" ]] || return 0

    if [[ "${recursion}" == "recursive" ]]; then
        git -C "${repository}" submodule sync --recursive
        git -C "${repository}" submodule update --init --recursive
    else
        git -C "${repository}" submodule sync
        git -C "${repository}" submodule update --init
    fi
}

cd "${ROOT_DIR}"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "${ROOT_DIR} is not a Git working tree"

require_parent_files_clean

log "synchronizing top-level submodule URLs"
git submodule sync

for path in "${SOURCE_PATHS[@]}"; do
    initialize_source_if_missing "${path}"
    update_source "${path}"
done

log "synchronizing nested submodules to their recorded commits"
sync_nested_submodules "boot/Adafruit_nRF52_Bootloader" "direct"
sync_nested_submodules "recv/SlimeVR-Tracker-nRF-Receiver" "recursive"
sync_nested_submodules "tracker/SlimeVR-Tracker-nRF" "recursive"

if git diff --quiet -- "${SOURCE_PATHS[@]}" &&
    git diff --cached --quiet -- "${SOURCE_PATHS[@]}"; then
    log "all source repositories were already current"
else
    log "source references changed; review and test before committing"
    git status --short
    git diff --submodule=log -- "${SOURCE_PATHS[@]}"
    git diff --cached --submodule=log -- "${SOURCE_PATHS[@]}"
fi
