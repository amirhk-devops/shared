#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Deployment Bootstrap
# Downloads the package image, extracts deployment files,
# and runs the main deployment script.
#
# ============================================================

# Paths can be overridden with --root, --ai-dir and --deploy-dir.
ROOT_OVERRIDE=""
AI_DIR_OVERRIDE=""
DEPLOY_DIR_OVERRIDE=""
START_ALL_COMPOSE="false"

while (($#)); do
    case "$1" in
        --root)
            (($# >= 2)) || { echo "ERROR: --root requires a value." >&2; exit 1; }
            ROOT_OVERRIDE="$2"; shift 2 ;;
        --ai-dir)
            (($# >= 2)) || { echo "ERROR: --ai-dir requires a value." >&2; exit 1; }
            AI_DIR_OVERRIDE="$2"; shift 2 ;;
        --deploy-dir)
            (($# >= 2)) || { echo "ERROR: --deploy-dir requires a value." >&2; exit 1; }
            DEPLOY_DIR_OVERRIDE="$2"; shift 2 ;;
        --start-all-compose)
            (($# >= 2)) || { echo "ERROR: --start-all-compose requires true or false." >&2; exit 1; }
            START_ALL_COMPOSE="$2"; shift 2 ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
    esac
done

ROOT="${ROOT_OVERRIDE:-${ROOT:-/opt/chargoon}}"
AI_DIR="${AI_DIR_OVERRIDE:-${AI_DIR:-$ROOT/ai}}"
DEPLOY_DIR="${DEPLOY_DIR_OVERRIDE:-${DEPLOY_DIR:-$ROOT/ai-deploy}}"

mkdir -p "$ROOT" "$DEPLOY_DIR" || {
    echo "ERROR: Could not prepare deployment directories." >&2
    exit 1
}

IMAGE_REGISTRY="devops.chargoon.net:8083"
IMAGE_NAMESPACE="ai"
IMAGE_TAG="latest"
PACKAGE_IMAGE_NAME="chargoon-deployment-package"

IMAGE_SOURCE="${IMAGE_SOURCE:-registry}"
PACKAGE_IMAGE_TAR="${PACKAGE_IMAGE_TAR:-}"
SERVICE_IMAGE_TAR_DIR="${SERVICE_IMAGE_TAR_DIR:-}"

TEMP_DIR=""
CONTAINER_ID=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
    echo >&2
    echo "ERROR: $*" >&2
    exit 1
}

cleanup() {
    local exit_code=$?

    if [[ -n "$CONTAINER_ID" ]]; then
        docker rm "$CONTAINER_ID" >/dev/null 2>&1 || true
    fi

    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR" || true
    fi

    exit "$exit_code"
}

# ------------------------------------------------------------
# 1. Prerequisites
# ------------------------------------------------------------

command -v docker >/dev/null 2>&1 ||
    fail "Docker is not installed."

command -v tar >/dev/null 2>&1 ||
    fail "tar command is not available."

command -v find >/dev/null 2>&1 ||
    fail "find command is not available."

docker info >/dev/null 2>&1 ||
    fail "Docker daemon is not available for the current user."

docker compose version >/dev/null 2>&1 ||
    fail "Docker Compose V2 is required."

[[ "$IMAGE_SOURCE" =~ ^(local|registry|tar)$ ]] ||
    fail "Invalid IMAGE_SOURCE: $IMAGE_SOURCE"

[[ "$START_ALL_COMPOSE" =~ ^(true|false)$ ]] ||
    fail "Invalid --start-all-compose value: $START_ALL_COMPOSE (expected true or false)"

log "Running as: $(id -un) (UID=$(id -u), GID=$(id -g))"

PACKAGE_IMAGE="$IMAGE_REGISTRY/$IMAGE_NAMESPACE/$PACKAGE_IMAGE_NAME:$IMAGE_TAG"

trap cleanup EXIT

# ------------------------------------------------------------
# 2. Prepare Package Image
# ------------------------------------------------------------

case "$IMAGE_SOURCE" in
    local)
        docker image inspect "$PACKAGE_IMAGE" >/dev/null 2>&1 ||
            fail "Package image not found locally: $PACKAGE_IMAGE"
        ;;

    registry)
        log "Pulling package image: $PACKAGE_IMAGE"

        docker pull "$PACKAGE_IMAGE" ||
            fail "Failed to pull package image."
        ;;

    tar)
        [[ -n "$PACKAGE_IMAGE_TAR" ]] ||
            fail "PACKAGE_IMAGE_TAR must be specified."

        [[ -f "$PACKAGE_IMAGE_TAR" ]] ||
            fail "Package image TAR not found: $PACKAGE_IMAGE_TAR"

        docker load -i "$PACKAGE_IMAGE_TAR" ||
            fail "Failed to load package image TAR."
        ;;
esac

docker image inspect "$PACKAGE_IMAGE" >/dev/null 2>&1 ||
    fail "Package image is unavailable: $PACKAGE_IMAGE"

TARGET_VERSION="$(
    docker image inspect \
        -f '{{ index .Config.Labels "chargoon.version" }}' \
        "$PACKAGE_IMAGE"
)"

[[ "$TARGET_VERSION" =~ ^[0-9]{8}$ ]] ||
    fail "Invalid or missing chargoon.version label on package image."

log "Package version: $TARGET_VERSION"

# ------------------------------------------------------------
# 3. Extract Package to a temporary directory
# ------------------------------------------------------------

log "Extracting deployment package..."

TEMP_DIR="$(mktemp -d "$ROOT/ai-package.XXXXXX")" ||
    fail "Could not create temporary package directory."

CONTAINER_ID="$(docker create "$PACKAGE_IMAGE")" ||
    fail "Could not create temporary package container."

docker cp \
    "$CONTAINER_ID:/package/package.tar.gz" \
    "$TEMP_DIR/package.tar.gz" ||
    fail "Could not copy package archive from package image."

docker rm "$CONTAINER_ID" >/dev/null ||
    fail "Could not remove temporary package container."

CONTAINER_ID=""

[[ -s "$TEMP_DIR/package.tar.gz" ]] ||
    fail "Package archive is missing or empty."

mkdir -p "$TEMP_DIR/extracted"

tar -xzf "$TEMP_DIR/package.tar.gz" \
    -C "$TEMP_DIR/extracted" ||
    fail "Package archive extraction failed."

[[ -f "$TEMP_DIR/extracted/.release-version" ]] ||
    fail "Package .release-version is missing."

ARCHIVE_VERSION="$(
    tr -d '\r\n' < "$TEMP_DIR/extracted/.release-version"
)"

[[ "$ARCHIVE_VERSION" == "$TARGET_VERSION" ]] ||
    fail "Package version mismatch. Image=$TARGET_VERSION Archive=$ARCHIVE_VERSION"

[[ -f "$TEMP_DIR/extracted/deploy-ai-for-customer.sh" ]] ||
    fail "Main deployment script is missing from package."

# ------------------------------------------------------------
# 4. Replace package contents, preserving backups
# ------------------------------------------------------------

log "Removing previous deployment package files..."

find "$DEPLOY_DIR" \
    -mindepth 1 \
    -maxdepth 1 \
    ! -name backups \
    -exec rm -rf -- {} + ||
    fail "Could not remove previous deployment package files."

log "Copying new deployment package files..."

cp -R --no-preserve=ownership \
    "$TEMP_DIR/extracted/." \
    "$DEPLOY_DIR/" ||
    fail "Could not copy extracted package files."

log "Package extracted successfully into: $DEPLOY_DIR"

# ------------------------------------------------------------
# 5. Run Main Deployment Script
# ------------------------------------------------------------

log "Starting main deployment script..."

TARGET_VERSION="$TARGET_VERSION" \
IMAGE_SOURCE="$IMAGE_SOURCE" \
PACKAGE_IMAGE_TAR="$PACKAGE_IMAGE_TAR" \
SERVICE_IMAGE_TAR_DIR="$SERVICE_IMAGE_TAR_DIR" \
    bash "$DEPLOY_DIR/deploy-ai-for-customer.sh" \
        --root "$ROOT" \
        --ai-dir "$AI_DIR" \
        --deploy-dir "$DEPLOY_DIR" \
        --start-all-compose "$START_ALL_COMPOSE" \
        --engine

log "Deployment script finished."
