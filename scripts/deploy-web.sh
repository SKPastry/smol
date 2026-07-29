#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly UPSTREAM_DIR="${ROOT_DIR}/web/slimenrf-ota-web"

usage() {
    cat <<'EOF'
Usage: ./scripts/deploy-web.sh <staging|production>

Build and deploy the combined OTA + remote-command site through the upstream
Cloudflare Pages configuration. A target is mandatory to prevent accidental
production deployment.
EOF
}

if (($# != 1)); then
    usage >&2
    exit 2
fi

case "$1" in
    staging | production)
        readonly DEPLOY_BRANCH="$1"
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

"${SCRIPT_DIR}/build-web.sh"

pnpm --dir "${UPSTREAM_DIR}" exec wrangler pages deploy dist \
    --branch "${DEPLOY_BRANCH}" \
    --commit-dirty=true
