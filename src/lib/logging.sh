#!/bin/bash
# Logging and utility functions module

# Logging function
log() {
    local level="$1"
    local message="$2"
    local log_string="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
    echo "$log_string" >> /backup/logs/backup.log
    echo "$log_string" >&2
}

# Get the first remote name from the rclone config
get_first_remote_name() {
    local config_file="$1"
    grep -m 1 "^\[.*\]" "$config_file" | sed 's/^\[\(.*\)\]/\1/'
}

# Convert LSN to numeric value for comparison
lsn_to_numeric() {
    local lsn="$1"
    if [[ "$lsn" =~ ^([0-9A-F]+)/([0-9A-F]+)$ ]]; then
        local high="${BASH_REMATCH[1]}"
        local low="${BASH_REMATCH[2]}"
        # Convert hex to decimal and combine
        echo $(( 0x$high * 4294967296 + 0x$low ))
    else
        echo "0"
    fi
}

# Calculate WAL growth between two LSNs
calculate_wal_growth() {
    local current_lsn="$1"
    local last_lsn="$2"

    if [ -z "$last_lsn" ] || [ "$last_lsn" = "null" ]; then
        echo "0"
        return
    fi

    local current_numeric=$(lsn_to_numeric "$current_lsn")
    local last_numeric=$(lsn_to_numeric "$last_lsn")

    if [ "$current_numeric" -gt "$last_numeric" ]; then
        echo $(( current_numeric - last_numeric ))
    else
        echo "0"
    fi
}

# Parse size with unit (KB, MB, GB) to bytes
parse_size_to_bytes() {
    local size_str="$1"
    local number=$(echo "$size_str" | sed 's/[^0-9.]//g')
    local unit=$(echo "$size_str" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')

    case "$unit" in
        "KB"|"K")
            echo $(echo "$number * 1024" | bc)
            ;;
        "MB"|"M")
            echo $(echo "$number * 1024 * 1024" | bc)
            ;;
        "GB"|"G")
            echo $(echo "$number * 1024 * 1024 * 1024" | bc)
            ;;
        "")
            # No unit, assume bytes
            echo "$number"
            ;;
        *)
            log "ERROR" "Unknown size unit: $unit. Use KB, MB, or GB"
            return 1
            ;;
    esac
}

# Wait for PostgreSQL to be ready
wait_for_postgres() {
    local max_wait="${1:-60}"
    local interval=5
    local waited=0
    
    log "INFO" "Waiting for PostgreSQL to become available..."
    
    while ! PGPASSWORD="$POSTGRES_PASSWORD" pg_isready -h 127.0.0.1 -U "$POSTGRES_USER" -d postgres -q; do
        if [ $waited -ge $max_wait ]; then
            log "ERROR" "Timeout waiting for PostgreSQL."
            return 1
        fi
        log "INFO" "PostgreSQL not ready yet, waiting $interval seconds... ($waited/$max_wait)"
        sleep $interval
        waited=$((waited + interval))
    done
    
    # Double-check with actual query to make sure user/password is working
    if ! PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d postgres -c "SELECT 1;" > /dev/null 2>&1; then
        log "ERROR" "PostgreSQL is running but authentication failed. Check POSTGRES_USER and POSTGRES_PASSWORD."
        return 1
    fi
    
    log "INFO" "PostgreSQL is ready and authentication confirmed."
    return 0
}

# Get database identifier for backup operations
get_database_identifier() {
    if [[ -n "$POSTGRES_DB" ]]; then
        # User specified a specific database for backup
        echo "$POSTGRES_DB"
    else
        # No specific database specified, use stanza name as identifier
        echo "${PGBACKREST_STANZA:-main}"
    fi
}