
#!/usr/bin/env bash
# chmod +x deploy-ai.sh
# ./deploy-ai.sh <SOURCE> <DEST> <IMAGE_TAG> <PROJECT_NAME> <BUILD_NUMBER>

set -Eeuo pipefail

# ==================================================
# 1. Parameters
# ==================================================

SOURCE="${1:-}"
DEST="${2:-}"
IMAGE_TAG="${3:-}"
PROJECT_NAME="${4:-}"
BUILD_NUMBER="${5:-local}"

if [[ -z "$SOURCE" || -z "$DEST" || -z "$IMAGE_TAG" ]]; then
    echo "Usage: $0 <SOURCE> <DEST> <IMAGE_TAG> <PROJECT_NAME> <BUILD_NUMBER>"
    exit 1
fi

export IMAGE_TAG

echo "SOURCE: $SOURCE"
echo "DEST: $DEST"
echo "IMAGE_TAG: $IMAGE_TAG"

# ==================================================
# 2. Common Functions
# ==================================================

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

copy_compose() {
    local name="$1"

    [[ -f "$SOURCE/$name" ]] || fail "Source file not found: $SOURCE/$name"

    cp -f -- "$SOURCE/$name" "$DEST/$name"
    echo "Copied: $name"
}

set_env_value() {
    local env_file="$1"
    local key="$2"
    local value="$3"
    local tmp_file

    tmp_file=$(mktemp "${env_file}.tmp.XXXXXX") || return 1

    if ! awk -v key="$key" -v value="$value" '
        BEGIN { found = 0 }

        index($0, key "=") == 1 {
            print key "=" value
            found = 1
            next
        }

        { print }

        END {
            if (!found)
                print key "=" value
        }
    ' "$env_file" > "$tmp_file"; then
        rm -f -- "$tmp_file"
        return 1
    fi

    chmod --reference="$env_file" "$tmp_file" || {
        rm -f -- "$tmp_file"
        return 1
    }

    mv -f -- "$tmp_file" "$env_file"
}

copy_config() {
    local source_file="$1"
    local dest_file="$2"

    if [[ ! -f "$source_file" ]]; then
        echo "Source config not found, skipping: $source_file"
        return
    fi

    if [[ -f "$CONFIG_DEST/$dest_file" ]]; then
        echo "Already exists, skipping: $dest_file"
        return
    fi

    cp -- "$source_file" "$CONFIG_DEST/$dest_file"
    echo "Copied: $source_file -> $dest_file"
}

# ==================================================
# 3. Validate Environment
# ==================================================

[[ -d "$SOURCE" ]] || fail "Source directory not found: $SOURCE"

command -v docker >/dev/null 2>&1 || fail "Docker not found."
command -v ss >/dev/null 2>&1 || fail "ss not found."
command -v sysctl >/dev/null 2>&1 || fail "sysctl not found."

docker compose version >/dev/null 2>&1 || fail "Docker Compose V2 not found."
docker info >/dev/null 2>&1 || fail "Cannot access Docker."

mkdir -p -- "$DEST"

SOURCE="$(realpath -e -- "$SOURCE")"
DEST="$(realpath -e -- "$DEST")"

[[ "$SOURCE" != "$DEST" ]] || fail "Source and destination must differ."

# ==================================================
# 4. Copy Compose Files
# ==================================================

echo "[1/6] Copying Compose files..."

copy_compose "docker-compose.yml"
copy_compose "docker-compose-messagebus.yml"
copy_compose "docker-compose-referral.yml"
copy_compose "docker-compose-control-panel.yml"

# ==================================================
# 5. Dynamic Port Allocation
# ==================================================

get_port_suffixes() {
    local env_file="$1"

    awk '
        /^[[:space:]]*#/ || !/=/ { next }

        {
            line = $0
            sub(/^[^=]*=/, "", line)

            while (match(line, /\$\{PORT_BASE\}[0-9]+/)) {
                item = substr(line, RSTART, RLENGTH)
                sub(/^\$\{PORT_BASE\}/, "", item)

                print item
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' "$env_file" | sort -u
}

load_ephemeral_range() {
    local output

    output=$(sysctl -n net.ipv4.ip_local_port_range) || return 1

    read -r EPHEMERAL_MIN EPHEMERAL_MAX <<< "$output"

    [[ "$EPHEMERAL_MIN" =~ ^[0-9]+$ ]] || return 1
    [[ "$EPHEMERAL_MAX" =~ ^[0-9]+$ ]] || return 1

    (( EPHEMERAL_MIN <= EPHEMERAL_MAX ))
}

is_port_available() {
    local port="$1"

    # Valid port range
    (( port >= 1024 && port <= 65535 )) || return 1

    # Reserved infrastructure ports
    local reserved_ports=(
        20 21 22 23 25
        53 67 68 69
        80 110 111 123
        135 137 138 139
        143 161 162
        389 443 445
        465 514 587
        631 636
        993 995
        1433 1521
        1900 2049
        2375 2376
        3306 3389
        5432 5672 5900 6379
        8080 8081 8082 8083
        9090 9200 9300
        5353 5355
    )

    local reserved

    for reserved in "${reserved_ports[@]}"; do
        if (( port == reserved )); then
            return 1
        fi
    done

    # Avoid ephemeral port range
    if (( port >= EPHEMERAL_MIN && port <= EPHEMERAL_MAX )); then
        return 1
    fi

    # Check host listening ports directly
    if ss -H -lntu | awk -v p="$port" '
        {
            address = $5
            sub(/^.*:/, "", address)

            if (address == p)
                found = 1
        }

        END { exit !found }
    '; then
        return 1
    fi

    # Check Docker published ports directly
    if docker ps --format '{{.Ports}}' 2>/dev/null |
        grep -Eq ":${port}->"; then
        return 1
    fi

    return 0
}

are_all_ports_available() {
    local base="$1"
    local suffix
    local port

    PORTS_AVAILABLE=true

    for suffix in "${PORT_SUFFIXES[@]}"; do

        port=$((10#${base}${suffix}))

        if ! is_port_available "$port"; then
            echo "Port $port unavailable (PORT_BASE=$base). Trying another candidate..." >&3
            PORTS_AVAILABLE=false
        fi

    done

    return 0
}

calculate_base_range() {
    local suffix
    local factor
    local suffix_value
    local min_candidate
    local max_candidate
    local i

    MIN_BASE=2
    MAX_BASE=65535

    for suffix in "${PORT_SUFFIXES[@]}"; do

        [[ "$suffix" =~ ^[0-9]+$ ]] || return 1

        # More than 4 digits cannot produce a valid port
        if (( ${#suffix} > 4 )); then
            echo "Invalid PORT_BASE suffix: $suffix" >&3
            return 1
        fi

        factor=1

        for ((i = 0; i < ${#suffix}; i++)); do
            factor=$((factor * 10))
        done

        suffix_value=$((10#$suffix))

        min_candidate=$(((1024 - suffix_value + factor - 1) / factor))
        max_candidate=$(((65535 - suffix_value) / factor))

        if (( min_candidate > MIN_BASE )); then
            MIN_BASE=$min_candidate
        fi

        if (( max_candidate < MAX_BASE )); then
            MAX_BASE=$max_candidate
        fi

    done

    (( MIN_BASE < 2 )) && MIN_BASE=2

    (( MIN_BASE <= MAX_BASE ))
}

generate_port_base() {
    local env_file="$1"
    local project_name="$2"
    local build_number="$3"

    local range
    local start_offset
    local candidate
    local tested_count

    mapfile -t PORT_SUFFIXES < <(get_port_suffixes "$env_file")

    while (( ${#PORT_SUFFIXES[@]} == 0 )); do
        echo "No PORT_BASE references found. Retrying in 30 seconds..." >&3
        sleep 3
        mapfile -t PORT_SUFFIXES < <(get_port_suffixes "$env_file")
    done

    echo "Detected suffixes: ${PORT_SUFFIXES[*]}" >&3

    while true; do

        if ! calculate_base_range; then
            echo "No valid PORT_BASE range. Retrying in 30 seconds..." >&3
            sleep 3
            continue
        fi

        if ! load_ephemeral_range; then
            echo "Cannot read ephemeral port range. Retrying in 30 seconds..." >&3
            sleep 3
            continue
        fi

        range=$((MAX_BASE - MIN_BASE + 1))

        echo "Valid PORT_BASE range: $MIN_BASE - $MAX_BASE" >&3
        echo "Generated ports: ${#PORT_SUFFIXES[@]}" >&3

        tested_count=0
        start_offset=$((RANDOM % range))

        echo "Starting candidate: $((MIN_BASE + start_offset))" >&3

        while (( tested_count < range )); do

            candidate=$((MIN_BASE + (start_offset + tested_count) % range))
            tested_count=$((tested_count + 1))

            echo "Attempt $tested_count: PORT_BASE=$candidate" >&3

            are_all_ports_available "$candidate"

            if [[ "$PORTS_AVAILABLE" == true ]]; then
                echo "PORT_BASE=$candidate selected successfully." >&3
                echo "$candidate"
                return 0
            fi

        done

        echo "No available PORT_BASE found. Retrying in 30 seconds..." >&3
        sleep 3

    done
}

# ==================================================
# 6. Copy / Generate .env
# ==================================================

echo "[2/6] Copying .env if missing..."

if [[ -f "$SOURCE/.env.example" && ! -e "$DEST/.env" ]]; then

    cp -p -- "$SOURCE/.env.example" "$DEST/.env"

    ENV_FILE="$DEST/.env"

    [[ -n "$PROJECT_NAME" ]] || {
        rm -f -- "$ENV_FILE"
        fail "PROJECT_NAME is empty."
    }

    # Keep fd 3 connected to the original pipeline output.
    # Messages from generate_port_base must not enter PORT_BASE.
    exec 3>&1

    if ! PORT_BASE=$(generate_port_base \
        "$ENV_FILE" \
        "$PROJECT_NAME" \
        "$BUILD_NUMBER"); then

        exec 3>&-
        rm -f -- "$ENV_FILE"
        fail "Failed to allocate PORT_BASE."
    fi

    exec 3>&-

    echo "Selected PORT_BASE: $PORT_BASE"

    set_env_value "$ENV_FILE" "PROJECT_NAME" "$PROJECT_NAME" ||
        fail "Cannot update PROJECT_NAME."

    set_env_value "$ENV_FILE" "PORT_BASE" "$PORT_BASE" ||
        fail "Cannot update PORT_BASE."

    echo ".env updated!"

elif [[ -e "$DEST/.env" ]]; then

    echo "Existing .env preserved."

else

    fail "Source .env.example not found and destination .env does not exist."

fi

# ==================================================
# 7. Copy Configuration Files
# ==================================================

echo "[3/6] Copying configuration files..."

CONFIG_DEST="$DEST/configs"

mkdir -p -- "$CONFIG_DEST"

copy_config "$SOURCE/synchronization/config.json" "synchronization.config.json"
copy_config "$SOURCE/referral_machine/config.referral.json" "referral.config.json"
copy_config "$SOURCE/message_bus/src/config/mgb-88888888-8888-8888-8888-888888888888.json" "mgb-88888888-8888-8888-8888-888888888888.json"
copy_config "$SOURCE/commands.config.json" "commands.config.json"
copy_config "$SOURCE/config.json" "ai-engine.config.json"

# ==================================================
# 8. Create Volumes
# ==================================================

echo "[4/6] Creating volumes and setting permissions..."

if [[ ! -d "$DEST/volumes" ]]; then

    echo "Creating volumes directories..."

    for dir in \
        volumes \
        volumes/ai-engine-redisinsight \
        volumes/ai-engine-redisinsight/logs \
        volumes/ai-worker \
        volumes/ai-worker/rag_ingest \
        volumes/ai-worker/data \
        volumes/ai-worker/output \
        volumes/control-panel
    do
        mkdir -p -- "$DEST/$dir"
    done

    chmod -R 777 -- "$DEST/volumes"

    echo "Volumes directories created successfully."

else

    echo "Volumes directory already exists. Skipping initialization."

fi

# ==================================================
# 9. Load Environment
# ==================================================

[[ -f "$DEST/.env" ]] || fail "Environment file not found: $DEST/.env"

set -a
source "$DEST/.env"
set +a

[[ -n "${PROJECT_NAME:-}" ]] || fail "PROJECT_NAME is missing in .env"

NETWORK="${PROJECT_NAME}-ai-chargoon-network"

# ==================================================
# 10. Ensure Docker Network
# ==================================================

echo "[5/6] Ensuring Docker network exists..."

if docker network inspect "$NETWORK" >/dev/null 2>&1; then
    echo "Network already exists: $NETWORK"
else
    docker network create "$NETWORK" >/dev/null
    echo "Created network: $NETWORK"
fi

# ==================================================
# 11. Run Docker Compose
# ==================================================

echo "[6/6] Running Docker Compose..."

cd -- "$DEST"

echo "Working directory: $(pwd)"

docker compose -f docker-compose.yml up -d 2>&1

docker compose -f docker-compose-messagebus.yml up -d 2>&1

docker compose -f docker-compose-referral.yml up -d 2>&1
docker compose -f docker-compose-control-panel.yml up -d 2>&1

echo "Deployment completed successfully."
