
#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s nullglob

# ============================================================
# 1. Configuration
# ============================================================

# Paths can be overridden with --root, --ai-dir and --deploy-dir.
ROOT_OVERRIDE=""
AI_DIR_OVERRIDE=""
DEPLOY_DIR_OVERRIDE=""
ENGINE_MODE=false
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
        --engine)
            ENGINE_MODE=true; shift ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
    esac
done

ROOT="${ROOT_OVERRIDE:-${ROOT:-/opt/chargoon}}"
AI_DIR="${AI_DIR_OVERRIDE:-${AI_DIR:-$ROOT/ai}}"
DEPLOY_DIR="${DEPLOY_DIR_OVERRIDE:-${DEPLOY_DIR:-$ROOT/ai-deploy}}"

IMAGE_REGISTRY="devops.chargoon.net:8083"
IMAGE_NAMESPACE="ai"
IMAGE_TAG="latest"

# Supported values: local | registry | tar
IMAGE_SOURCE="${IMAGE_SOURCE:-local}"

PACKAGE_IMAGE_NAME="chargoon-deployment-package"

PACKAGE_IMAGE_TAR="${PACKAGE_IMAGE_TAR:-}"
SERVICE_IMAGE_TAR_DIR="${SERVICE_IMAGE_TAR_DIR:-}"

SERVICE_IMAGES=(
    "chargoon-ai-worker"
    "message-bus-api"
    "chargoon-ai-referral"
    "chargoon-ai-synchronization"
    "chargoon-ai-control-panel"
)

COMPOSE_FILES=(
    "docker-compose-control-panel.yml"
    "docker-compose.yml"
    "docker-compose-messagebus.yml"
    "docker-compose-referral.yml"
)

CONTROL_PANEL_COMPOSE="docker-compose-control-panel.yml"

VOLUME_DIRS=(
    "volumes"
    "volumes/ai-engine-redisinsight"
    "volumes/ai-engine-redisinsight/logs"
    "volumes/ai-worker"
    "volumes/ai-worker/rag_ingest"
    "volumes/ai-worker/data"
    "volumes/ai-worker/output"
    "volumes/control-panel"
)

RELEASE_FILE="$DEPLOY_DIR/.release-version"

BACKUP_DIR=""
PROJECT_NAME=""
NETWORK=""
IS_UPGRADE=false
TARGET_VERSION=""

TEMP_DIR=""
CONTAINER_ID=""

# ============================================================
# 2. Common Functions
# ============================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
    echo >&2
    echo "ERROR: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        fail "Required command not found: $1"
}

get_image_name() {
    local image="$1"
    local tag="${2:-$IMAGE_TAG}"

    echo "${IMAGE_REGISTRY}/${IMAGE_NAMESPACE}/${image}:${tag}"
}

read_env_value() {
    local env_file="$1"
    local key="$2"

    awk -v key="$key" '
        /^[[:space:]]*#/ || !/=/ {
            next
        }

        {
            name = $0
            sub(/=.*/, "", name)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)

            if (name == key) {
                value = $0
                sub(/^[^=]*=/, "", value)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)

                if (value ~ /^".*"$/ || value ~ /^'\''.*'\''$/) {
                    value = substr(value, 2, length(value) - 2)
                }

                print value
                exit
            }
        }
    ' "$env_file"
}

read_release_version() {
    [[ -f "$RELEASE_FILE" ]] ||
        fail "Package .release-version is missing."

    TARGET_VERSION="$(tr -d '\r\n' < "$RELEASE_FILE")"

    [[ "$TARGET_VERSION" =~ ^[0-9]{8}$ ]] ||
        fail "Invalid or missing version in .release-version."
}

cleanup() {
    if [[ -n "$CONTAINER_ID" ]]; then
        docker rm "$CONTAINER_ID" >/dev/null 2>&1 || true
    fi

    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

# ============================================================
# 3. Validate System Prerequisites
# ============================================================

check_prerequisites() {
    log "Checking system prerequisites..."

    require_command docker
    require_command tar
    require_command cp
    require_command awk
    require_command date
    require_command grep
    require_command flock
    require_command mktemp
    require_command find
    require_command tr

    docker info >/dev/null 2>&1 ||
        fail "Docker daemon is not available for the current user."

    docker compose version >/dev/null 2>&1 ||
        fail "Docker Compose V2 is required."

    [[ "$IMAGE_SOURCE" =~ ^(local|registry|tar)$ ]] ||
        fail "Invalid IMAGE_SOURCE: $IMAGE_SOURCE"

    mkdir -p "$ROOT" "$AI_DIR" "$DEPLOY_DIR" ||
        fail "Could not create deployment directories."

    log "System prerequisites validated."
}




# ============================================================
# 4. Deployment Lock
# ============================================================

create_lock() {
    exec 9>"$ROOT/.ai-deploy.lock" ||
        fail "Could not create deployment lock file."

    flock -n 9 ||
        fail "Another deployment process is already running."
}

# ============================================================
# 5. Create Backup Directory
# ============================================================

create_backup_directory() {
    local date_name
    local timestamp

    date_name="$(date '+%Y%m%d')"
    BACKUP_DIR="$DEPLOY_DIR/backups/$date_name"

    if [[ -e "$BACKUP_DIR" ]]; then
        timestamp="$(date '+%Y%m%d_%H%M%S')"
        BACKUP_DIR="$DEPLOY_DIR/backups/$timestamp"
    fi

    mkdir -p "$BACKUP_DIR" ||
        fail "Could not create backup directory."

    [[ -w "$BACKUP_DIR" ]] ||
        fail "No write permission on backup directory: $BACKUP_DIR"

    log "Backup directory: $BACKUP_DIR"
}

# ============================================================
# 6. Detect Existing Installation
# ============================================================

detect_installation() {
    if [[ -f "$AI_DIR/.env" ]] ||
       [[ -f "$AI_DIR/.release-version" ]] ||
       [[ -f "$AI_DIR/docker-compose.yml" ]] ||
       [[ -f "$AI_DIR/docker-compose-messagebus.yml" ]] ||
       [[ -f "$AI_DIR/docker-compose-referral.yml" ]] ||
       [[ -f "$AI_DIR/docker-compose-control-panel.yml" ]]; then

        IS_UPGRADE=true
    else
        IS_UPGRADE=false
    fi

    log "Installation type: $(
        [[ "$IS_UPGRADE" == true ]] && echo Upgrade || echo New Installation
    )"
}

# ============================================================
# 7. Backup Existing Environment Files
# ============================================================

backup_current_files() {
    log "Backing up current environment files..."

    [[ "$IS_UPGRADE" == true ]] || {
        log "New installation. No existing files to back up."
        return 0
    }

    local files=(
        ".env"
        ".release-version"
        "docker-compose.yml"
        "docker-compose-messagebus.yml"
        "docker-compose-referral.yml"
        "docker-compose-control-panel.yml"
    )

    local file

    for file in "${files[@]}"; do
        if [[ -f "$AI_DIR/$file" ]]; then
            cp -R --no-preserve=ownership \
                "$AI_DIR/$file" "$BACKUP_DIR/" ||
                fail "Could not back up: $file"
        fi
    done

    if [[ -d "$AI_DIR/configs" ]]; then
        cp -R --no-preserve=ownership \
            "$AI_DIR/configs" "$BACKUP_DIR/" ||
            fail "Could not back up configuration files."
    fi

    log "Environment files backed up."
}

# ============================================================
# 8. Backup Existing Service Images
# ============================================================

backup_images() {
    log "Backing up existing service images..."

    local image
    local source_image
    local backup_image
    local backup_tag

    backup_tag="backup-$(date '+%Y%m%d_%H%M%S')"

    : > "$BACKUP_DIR/image-tags.txt" ||
        fail "Could not create image backup manifest."

    for image in "${SERVICE_IMAGES[@]}"; do

        source_image="$(get_image_name "$image")"
        backup_image="$(get_image_name "$image" "$backup_tag")"

        if ! docker image inspect "$source_image" >/dev/null 2>&1; then
            log "Image not found locally, skipping: $source_image"
            continue
        fi

        docker image inspect "$backup_image" >/dev/null 2>&1 &&
            fail "Backup image tag already exists: $backup_image"

        docker tag "$source_image" "$backup_image" ||
            fail "Failed to backup image: $source_image"

        printf '%s %s\n' "$source_image" "$backup_image" \
            >> "$BACKUP_DIR/image-tags.txt"

        log "Image backup created: $backup_image"
    done

    log "Service image backup completed."
}

# ============================================================
# 9. Prepare Package Image
# ============================================================

prepare_package_image() {
    log "Preparing deployment package image..."

    local package_image

    package_image="$(get_image_name "$PACKAGE_IMAGE_NAME")"

    case "$IMAGE_SOURCE" in

        local)
            docker image inspect "$package_image" >/dev/null 2>&1 ||
                fail "Package image not found locally: $package_image"
            ;;

        registry)
            log "Pulling package image: $package_image"

            docker pull "$package_image" ||
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

    docker image inspect "$package_image" >/dev/null 2>&1 ||
        fail "Package image is unavailable: $package_image"

    TARGET_VERSION="$(
        docker image inspect \
            -f '{{ index .Config.Labels "chargoon.version" }}' \
            "$package_image"
    )"

    [[ "$TARGET_VERSION" =~ ^[0-9]{8}$ ]] ||
        fail "Invalid or missing chargoon.version label on package image."

    log "Package version: $TARGET_VERSION"
}

# ============================================================
# 10. Extract Deployment Package
# ============================================================

extract_package() {
    log "Extracting deployment package..."

    local package_image
    local archive_version
    local item
    local blocked_dir

    package_image="$(get_image_name "$PACKAGE_IMAGE_NAME")"

    TEMP_DIR="$(mktemp -d "$ROOT/ai-package.XXXXXX")" ||
        fail "Could not create temporary directory."

    CONTAINER_ID="$(docker create "$package_image")" ||
        fail "Could not create temporary package container."

    docker cp \
        "$CONTAINER_ID:/package/package.tar.gz" \
        "$TEMP_DIR/package.tar.gz" ||
        fail "Could not copy package archive from image."

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

    archive_version="$(
        tr -d '\r\n' < "$TEMP_DIR/extracted/.release-version"
    )"

    [[ "$archive_version" == "$TARGET_VERSION" ]] ||
        fail "Package version mismatch. Image=$TARGET_VERSION Archive=$archive_version"

    [[ -f "$TEMP_DIR/extracted/deploy-ai-for-customer.sh" ]] ||
        fail "Deployment script is missing from package."

    # Preserve backups; replace all other package contents.
    find "$DEPLOY_DIR" \
        -mindepth 1 \
        -maxdepth 1 \
        ! -name backups \
        -exec rm -rf -- {} + ||
        fail "Could not clean previous deployment package."

    cp -R --no-preserve=ownership \
        "$TEMP_DIR/extracted/." "$DEPLOY_DIR/" ||
        fail "Could not copy extracted package files."

    chmod +x "$DEPLOY_DIR/deploy-ai-for-customer.sh" ||
        fail "Could not set deployment script permissions."

    rm -rf -- "$TEMP_DIR"
    TEMP_DIR=""

    log "Package extracted into: $DEPLOY_DIR"
}

# ============================================================
# 11. Prepare Service Images
# ============================================================

prepare_service_images() {
    log "Preparing service images using: $IMAGE_SOURCE"

    local image
    local image_name
    local tar_file
    local tar_files

    case "$IMAGE_SOURCE" in

        local)
            log "Using local Docker images."

            for image in "${SERVICE_IMAGES[@]}"; do
                image_name="$(get_image_name "$image")"

                docker image inspect "$image_name" >/dev/null 2>&1 ||
                    fail "Required image not found locally: $image_name"
            done
            ;;

        registry)
            log "Pulling service images from registry..."

            for image in "${SERVICE_IMAGES[@]}"; do
                image_name="$(get_image_name "$image")"

                log "Pulling $image_name"

                docker pull "$image_name" ||
                    fail "Failed to pull image: $image_name"
            done
            ;;

        tar)
            [[ -n "$SERVICE_IMAGE_TAR_DIR" ]] ||
                fail "SERVICE_IMAGE_TAR_DIR must be specified."

            [[ -d "$SERVICE_IMAGE_TAR_DIR" ]] ||
                fail "Service image TAR directory not found."

            tar_files=("$SERVICE_IMAGE_TAR_DIR"/*.tar)

            ((${#tar_files[@]} > 0)) ||
                fail "No service image TAR files found."

            for tar_file in "${tar_files[@]}"; do
                log "Loading image archive: $tar_file"

                docker load -i "$tar_file" ||
                    fail "Failed to load image TAR: $tar_file"
            done

            for image in "${SERVICE_IMAGES[@]}"; do
                image_name="$(get_image_name "$image")"

                docker image inspect "$image_name" >/dev/null 2>&1 ||
                    fail "Image missing after TAR loading: $image_name"
            done
            ;;
    esac

    log "All service images are available."
}

# ============================================================
# 12. Validate Service Image Versions
# ============================================================

validate_images_version() {
    log "Validating service image versions..."

    local image
    local image_name
    local image_version

    for image in "${SERVICE_IMAGES[@]}"; do

        image_name="$(get_image_name "$image")"

        image_version="$(
            docker image inspect \
                -f '{{ index .Config.Labels "chargoon.version" }}' \
                "$image_name" 2>/dev/null
        )" || fail "Required image is missing: $image_name"

        [[ "$image_version" == "$TARGET_VERSION" ]] ||
            fail "Version mismatch for $image_name. Expected=$TARGET_VERSION Actual=${image_version:-missing}"

        log "Validated: $image_name"
    done

    log "All service image versions are valid."
}

# ============================================================
# 13. Stop Existing Services
# ============================================================

stop_current_services() {
    log "Stopping existing AI services..."

    [[ "$IS_UPGRADE" == true ]] || {
        log "New installation. No existing services to stop."
        return 0
    }

    [[ -f "$AI_DIR/.env" ]] ||
        fail "Existing installation detected but .env is missing."

    local file

    for file in "${COMPOSE_FILES[@]}"; do

        [[ -f "$AI_DIR/$file" ]] || continue

        log "Stopping services from $file"

        docker compose \
            --project-directory "$AI_DIR" \
            --env-file "$AI_DIR/.env" \
            -f "$AI_DIR/$file" \
            stop 2>&1 ||
            fail "Could not stop services from $file"
    done

    log "Existing services stopped."
}

# ============================================================
# 14. Backup Existing Volumes
# ============================================================

backup_current_volumes() {
    log "Backing up existing volume files..."

    [[ "$IS_UPGRADE" == true ]] || {
        log "New installation. No existing volumes to back up."
        return 0
    }

    [[ -d "$AI_DIR/volumes" ]] || {
        log "No existing volumes directory found."
        return 0
    }

    tar -czf "$BACKUP_DIR/volumes.tar.gz" \
        -C "$AI_DIR" volumes ||
        fail "Volume backup failed."

    log "Volume backup completed."
}

# ============================================================
# 15. Prepare Initial Environment
# ============================================================

prepare_initial_environment() {
    log "Preparing initial environment..."

    mkdir -p "$AI_DIR"

    if [[ ! -f "$AI_DIR/.env" ]]; then

        [[ -f "$DEPLOY_DIR/.env" ]] ||
            fail ".env is missing."

        cp --no-preserve=ownership \
            "$DEPLOY_DIR/.env" "$AI_DIR/.env" ||
            fail "Could not create initial .env."

        log "Initial .env created."
    else
        log "Existing .env preserved."
    fi

    mkdir -p "$AI_DIR/configs"
    mkdir -p "$AI_DIR/volumes"

    if [[ -d "$DEPLOY_DIR/configs" ]]; then
        cp -R --update=none --no-preserve=ownership \
            "$DEPLOY_DIR/configs/." "$AI_DIR/configs/" ||
            fail "Could not copy initial configuration files."
    fi

    log "Initial environment prepared."
}

# ============================================================
# 16. Prepare Volume Directories
# ============================================================

prepare_volume_directories() {
    log "Creating required volume directories..."

    local dir
    local volume_path

    for dir in "${VOLUME_DIRS[@]}"; do
        volume_path="$AI_DIR/$dir"

        if [[ ! -d "$volume_path" ]]; then
            mkdir -p "$volume_path" ||
                fail "Could not create volume directory: $volume_path"

            chmod 777 "$volume_path" ||
                fail "Could not set permissions: $volume_path"
        fi
    done

    log "Volume directories created."
}

# ============================================================
# 17. Copy Initial Volume Files Without Overwriting
# ============================================================

prepare_volume_files() {
    log "Copying initial volume files..."

    [[ -d "$DEPLOY_DIR/volumes" ]] || {
        log "No initial volume files in package."
        return 0
    }

    mkdir -p "$AI_DIR/volumes"

    cp -R --update=none --no-preserve=ownership \
        "$DEPLOY_DIR/volumes/." "$AI_DIR/volumes/" ||
        fail "Could not copy initial volume files."

    log "Initial volume files copied without overwriting existing files."
}

# ============================================================
# 18. Prepare Shared Docker Network
# ============================================================

prepare_network() {
    log "Preparing Docker network..."

    [[ -f "$AI_DIR/.env" ]] ||
        fail "Environment file not found: $AI_DIR/.env"

    PROJECT_NAME="$(read_env_value "$AI_DIR/.env" "PROJECT_NAME")"

    [[ -n "$PROJECT_NAME" ]] ||
        fail "PROJECT_NAME is missing in .env."

    [[ "$PROJECT_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] ||
        fail "Invalid PROJECT_NAME: $PROJECT_NAME"

    NETWORK="${PROJECT_NAME}-ai-chargoon-network"

    if docker network inspect "$NETWORK" >/dev/null 2>&1; then
        log "Docker network already exists: $NETWORK"
    else
        docker network create "$NETWORK" >/dev/null ||
            fail "Could not create Docker network: $NETWORK"

        log "Docker network created: $NETWORK"
    fi
}

# ============================================================
# 19. Validate Control Panel Compose
# ============================================================

validate_control_panel() {
    log "Copying Compose files to main directory..."

    local file

    for file in "${COMPOSE_FILES[@]}"; do
        [[ -f "$DEPLOY_DIR/$file" ]] ||
            fail "Compose file is missing: $file"

        cp --no-preserve=ownership \
            "$DEPLOY_DIR/$file" "$AI_DIR/$file" ||
            fail "Could not copy Compose file: $file"
    done

    log "Compose files copied to: $AI_DIR"

    log "Validating Control Panel Compose configuration..."

    [[ -f "$AI_DIR/$CONTROL_PANEL_COMPOSE" ]] ||
        fail "Control Panel Compose file is missing."

    (
        cd "$AI_DIR" || exit 1

        docker compose \
            --env-file .env \
            -f "$CONTROL_PANEL_COMPOSE" \
            config --quiet
    ) ||
        fail "Control Panel Compose configuration is invalid."

    log "Control Panel Compose configuration is valid."
}

# ============================================================
# 20. Start Compose Services
# ============================================================

start_compose_services() {
    local file

    if [[ "$START_ALL_COMPOSE" == "true" ]]; then
        log "Starting all Compose files..."

        for file in "${COMPOSE_FILES[@]}"; do
            log "Starting services from $file"

            cd "$AI_DIR" || exit 1
            docker compose \
                --project-directory "$AI_DIR" \
                --env-file "$AI_DIR/.env" \
                -f "$AI_DIR/$file" \
                up -d 2>&1 ||
                fail "Could not start services from $file"
        done

        log "All Compose files started successfully."
    else
        log "Starting Control Panel only..."

        cd "$AI_DIR" || exit 1
        docker compose \
            --project-directory "$AI_DIR" \
            --env-file "$AI_DIR/.env" \
            -f "$AI_DIR/$CONTROL_PANEL_COMPOSE" \
            up -d 2>&1 ||
            fail "Could not start Control Panel."

        log "Control Panel started successfully."
    fi
}

# ============================================================
# 21. Finish Deployment
# ============================================================

finish_deployment() {
    printf '%s\n' "$TARGET_VERSION" > "$AI_DIR/.release-version" ||
        fail "Could not write release version."

    log "============================================================"
    log "Deployment preparation completed successfully."
    log "============================================================"

    echo "Installation type : $([[ "$IS_UPGRADE" == true ]] && echo Upgrade || echo New Installation)"
    echo "Target version    : $TARGET_VERSION"
    echo "Image source      : $IMAGE_SOURCE"
    echo "Main directory    : $AI_DIR"
    echo "Deployment folder : $DEPLOY_DIR"
    echo "Backup directory  : $BACKUP_DIR"
    echo "Docker network    : $NETWORK"
    echo
    if [[ "$START_ALL_COMPOSE" == "true" ]]; then
        echo "All Compose files have been started."
    else
        echo "Only Control Panel has been started."
        echo "Continue configuration migration from Control Panel."
    fi
}

# ============================================================
# 22. Deployment Engine
# ============================================================

deployment_engine() {
    check_prerequisites
    read_release_version

    create_lock
    create_backup_directory
    detect_installation

    backup_current_files
    backup_images

    prepare_service_images
    validate_images_version

    stop_current_services
    # backup_current_volumes

    prepare_initial_environment
    prepare_volume_directories
    prepare_volume_files

    prepare_network
    validate_control_panel

    start_compose_services

    finish_deployment
}

# ============================================================
# 23. Bootstrap
# ============================================================

bootstrap() {
    check_prerequisites

    prepare_package_image
    extract_package

    log "Starting Deployment Engine..."

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
}

# ============================================================
# 24. Main
# ============================================================

trap cleanup EXIT

if [[ "$ENGINE_MODE" == true ]]; then
    deployment_engine
else
    bootstrap
fi
