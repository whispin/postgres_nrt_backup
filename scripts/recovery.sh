#!/bin/bash

# PostgreSQL Recovery Script
# This script handles automatic recovery from remote backup storage

set -e

source /backup/scripts/backup-functions.sh

# Recovery configuration
RECOVERY_TARGET_TIME="${RECOVERY_TARGET_TIME:-}"
RECOVERY_TARGET_NAME="${RECOVERY_TARGET_NAME:-}"
RECOVERY_TARGET_XID="${RECOVERY_TARGET_XID:-}"
RECOVERY_TARGET_LSN="${RECOVERY_TARGET_LSN:-}"
RECOVERY_TARGET_INCLUSIVE="${RECOVERY_TARGET_INCLUSIVE:-true}"
RECOVERY_TARGET_ACTION="${RECOVERY_TARGET_ACTION:-promote}"
RECOVERY_TEMP_DIR="/tmp/recovery"
RECOVERY_LOG_FILE="/backup/logs/recovery.log"

# Recovery log function
recovery_log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$RECOVERY_LOG_FILE"
    # Also log to main backup log
    log "$level" "RECOVERY: $message"
}

# Display recovery usage
show_recovery_usage() {
    echo "PostgreSQL Recovery Usage:"
    echo ""
    echo "Environment Variables:"
    echo "  RECOVERY_MODE=true                    # Enable recovery mode"
    echo "  RECOVERY_TARGET_TIME='YYYY-MM-DD HH:MM:SS'  # Recover to specific time"
    echo "  RECOVERY_TARGET_NAME='backup_label'   # Recover to named restore point"
    echo "  RECOVERY_TARGET_XID='12345'          # Recover to specific transaction ID"
    echo "  RECOVERY_TARGET_LSN='0/1234567'      # Recover to specific LSN"
    echo "  RECOVERY_TARGET_INCLUSIVE=true       # Include target in recovery"
    echo "  RECOVERY_TARGET_ACTION=promote       # Action after recovery (promote/pause/shutdown)"
    echo ""
    echo "Examples:"
    echo "  # Recover to latest backup"
    echo "  docker run -e RECOVERY_MODE=true your-image"
    echo ""
    echo "  # Recover to specific time"
    echo "  docker run -e RECOVERY_MODE=true \\"
    echo "             -e RECOVERY_TARGET_TIME='2025-07-10 14:30:00' \\"
    echo "             your-image"
    echo ""
}

# Check if recovery mode is enabled
is_recovery_mode() {
    [ "${RECOVERY_MODE:-false}" = "true" ]
}

# Validate recovery parameters
validate_recovery_params() {
    recovery_log "INFO" "Validating recovery parameters..."
    
    # Check if multiple targets are specified
    local target_count=0
    [ -n "$RECOVERY_TARGET_TIME" ] && target_count=$((target_count + 1))
    [ -n "$RECOVERY_TARGET_NAME" ] && target_count=$((target_count + 1))
    [ -n "$RECOVERY_TARGET_XID" ] && target_count=$((target_count + 1))
    [ -n "$RECOVERY_TARGET_LSN" ] && target_count=$((target_count + 1))
    
    if [ $target_count -gt 1 ]; then
        recovery_log "ERROR" "Multiple recovery targets specified. Please specify only one."
        return 1
    fi
    
    # Validate time format if specified
    if [ -n "$RECOVERY_TARGET_TIME" ]; then
        if ! date -d "$RECOVERY_TARGET_TIME" >/dev/null 2>&1; then
            recovery_log "ERROR" "Invalid RECOVERY_TARGET_TIME format: $RECOVERY_TARGET_TIME"
            recovery_log "INFO" "Expected format: 'YYYY-MM-DD HH:MM:SS'"
            return 1
        fi
    fi
    
    # Validate action
    case "$RECOVERY_TARGET_ACTION" in
        promote|pause|shutdown)
            ;;
        *)
            recovery_log "ERROR" "Invalid RECOVERY_TARGET_ACTION: $RECOVERY_TARGET_ACTION"
            recovery_log "INFO" "Valid actions: promote, pause, shutdown"
            return 1
            ;;
    esac
    
    recovery_log "INFO" "Recovery parameters validation passed"
    return 0
}

# Download backup repository from remote storage
download_backup_repository() {
    recovery_log "INFO" "Downloading backup repository from remote storage..."

    local db_identifier=$(get_database_identifier)
    local remote_repo_path="${RCLONE_REMOTE_PATH:-postgres-backups}/${db_identifier}/repository"
    local local_repo_path="/var/lib/pgbackrest"

    # Create local repository directory
    mkdir -p "$local_repo_path"
    chown postgres:postgres "$local_repo_path"

    # Check if remote repository exists
    if ! rclone lsf "${REMOTE_NAME}:${remote_repo_path}/" --config "$RCLONE_CONFIG_PATH" >/dev/null 2>&1; then
        recovery_log "ERROR" "Remote backup repository not found: ${REMOTE_NAME}:${remote_repo_path}/"
        recovery_log "INFO" "Attempting to find backup repository in legacy location..."

        # Try legacy location for backward compatibility
        local legacy_repo_path="${RCLONE_REMOTE_PATH:-postgres-backups}/${db_identifier}/base"
        if rclone lsf "${REMOTE_NAME}:${legacy_repo_path}/" --config "$RCLONE_CONFIG_PATH" >/dev/null 2>&1; then
            recovery_log "INFO" "Found backup repository in legacy location"
            remote_repo_path="$legacy_repo_path"
        else
            recovery_log "ERROR" "No backup repository found in any location"
            return 1
        fi
    fi

    recovery_log "INFO" "Downloading from ${REMOTE_NAME}:${remote_repo_path}/ to $local_repo_path"

    # Download repository with progress
    if rclone sync "${REMOTE_NAME}:${remote_repo_path}/" "$local_repo_path" \
        --config "$RCLONE_CONFIG_PATH" \
        --progress \
        --exclude="*.lock" \
        --exclude="*.tmp"; then
        recovery_log "INFO" "Backup repository downloaded successfully"

        # Set proper permissions
        chown -R postgres:postgres "$local_repo_path"
        chmod -R 750 "$local_repo_path"

        return 0
    else
        recovery_log "ERROR" "Failed to download backup repository"
        return 1
    fi
}

# List available backups
list_available_backups() {
    recovery_log "INFO" "Listing available backups..."
    
    local stanza_name="${PGBACKREST_STANZA:-main}"
    
    # List backups using pgBackRest
    if su-exec postgres pgbackrest --stanza="$stanza_name" info 2>/dev/null; then
        recovery_log "INFO" "Available backups listed above"
        return 0
    else
        recovery_log "WARN" "Could not list backups. Repository may be empty or corrupted."
        return 1
    fi
}

# Find best backup for recovery target
find_recovery_backup() {
    local stanza_name="${PGBACKREST_STANZA:-main}"
    local target_time="$1"
    
    recovery_log "INFO" "Finding best backup for recovery..."
    
    if [ -n "$target_time" ]; then
        recovery_log "INFO" "Looking for backup before: $target_time"
        
        # Get backup info in JSON format
        local backup_info=$(su-exec postgres pgbackrest --stanza="$stanza_name" info --output=json 2>/dev/null)
        
        if [ -n "$backup_info" ]; then
            # Find the latest backup before target time
            local best_backup=$(echo "$backup_info" | jq -r --arg target "$target_time" '
                .[] | .backup[] | 
                select(.timestamp.stop <= ($target | strptime("%Y-%m-%d %H:%M:%S") | mktime)) |
                .label' | tail -1)
            
            if [ -n "$best_backup" ] && [ "$best_backup" != "null" ]; then
                recovery_log "INFO" "Selected backup for recovery: $best_backup"
                echo "$best_backup"
                return 0
            else
                recovery_log "WARN" "No backup found before target time: $target_time"
                recovery_log "INFO" "Will use latest available backup"
            fi
        fi
    fi
    
    # Use latest backup if no specific target or no suitable backup found
    recovery_log "INFO" "Using latest available backup"
    echo "latest"
    return 0
}

# Prepare PostgreSQL data directory for recovery
prepare_data_directory() {
    recovery_log "INFO" "Preparing PostgreSQL data directory for recovery..."
    
    # Stop PostgreSQL if running
    if pgrep postgres >/dev/null; then
        recovery_log "INFO" "Stopping PostgreSQL for recovery..."
        pkill -TERM postgres || true
        sleep 5
        pkill -KILL postgres 2>/dev/null || true
    fi
    
    # Backup existing data directory if it exists
    if [ -d "$PGDATA" ] && [ "$(ls -A $PGDATA 2>/dev/null)" ]; then
        local backup_dir="${PGDATA}.backup.$(date +%Y%m%d_%H%M%S)"
        recovery_log "INFO" "Backing up existing data directory to: $backup_dir"
        mv "$PGDATA" "$backup_dir"
    fi
    
    # Create fresh data directory
    mkdir -p "$PGDATA"
    chown postgres:postgres "$PGDATA"
    chmod 700 "$PGDATA"
    
    recovery_log "INFO" "Data directory prepared for recovery"
    return 0
}

# Create recovery configuration
create_recovery_config() {
    recovery_log "INFO" "Creating recovery configuration..."
    
    local recovery_conf="$PGDATA/postgresql.auto.conf"
    local recovery_signal="$PGDATA/recovery.signal"
    
    # Create recovery.signal file to enable recovery mode
    touch "$recovery_signal"
    chown postgres:postgres "$recovery_signal"
    
    # Create recovery configuration
    cat > "$recovery_conf" << EOF
# Recovery configuration generated by backup system
# $(date)

# Basic recovery settings
restore_command = 'pgbackrest --stanza=${PGBACKREST_STANZA:-main} archive-get %f "%p"'
recovery_target_action = '${RECOVERY_TARGET_ACTION}'
recovery_target_inclusive = ${RECOVERY_TARGET_INCLUSIVE}

EOF

    # Add specific recovery target
    if [ -n "$RECOVERY_TARGET_TIME" ]; then
        echo "recovery_target_time = '$RECOVERY_TARGET_TIME'" >> "$recovery_conf"
        recovery_log "INFO" "Recovery target time: $RECOVERY_TARGET_TIME"
    elif [ -n "$RECOVERY_TARGET_NAME" ]; then
        echo "recovery_target_name = '$RECOVERY_TARGET_NAME'" >> "$recovery_conf"
        recovery_log "INFO" "Recovery target name: $RECOVERY_TARGET_NAME"
    elif [ -n "$RECOVERY_TARGET_XID" ]; then
        echo "recovery_target_xid = '$RECOVERY_TARGET_XID'" >> "$recovery_conf"
        recovery_log "INFO" "Recovery target XID: $RECOVERY_TARGET_XID"
    elif [ -n "$RECOVERY_TARGET_LSN" ]; then
        echo "recovery_target_lsn = '$RECOVERY_TARGET_LSN'" >> "$recovery_conf"
        recovery_log "INFO" "Recovery target LSN: $RECOVERY_TARGET_LSN"
    else
        recovery_log "INFO" "Recovery target: latest available"
    fi
    
    # Set proper permissions
    chown postgres:postgres "$recovery_conf"
    chmod 600 "$recovery_conf"
    
    recovery_log "INFO" "Recovery configuration created"
    return 0
}

# Perform database restore
perform_restore() {
    recovery_log "INFO" "Starting database restore..."
    
    local stanza_name="${PGBACKREST_STANZA:-main}"
    local backup_label="$1"
    
    # Build restore command
    local restore_cmd="pgbackrest --stanza=$stanza_name restore"
    
    if [ "$backup_label" != "latest" ]; then
        restore_cmd="$restore_cmd --set=$backup_label"
    fi
    
    # Add recovery target options for restore
    if [ -n "$RECOVERY_TARGET_TIME" ]; then
        restore_cmd="$restore_cmd --type=time --target='$RECOVERY_TARGET_TIME'"
    elif [ -n "$RECOVERY_TARGET_NAME" ]; then
        restore_cmd="$restore_cmd --type=name --target='$RECOVERY_TARGET_NAME'"
    elif [ -n "$RECOVERY_TARGET_XID" ]; then
        restore_cmd="$restore_cmd --type=xid --target='$RECOVERY_TARGET_XID'"
    elif [ -n "$RECOVERY_TARGET_LSN" ]; then
        restore_cmd="$restore_cmd --type=lsn --target='$RECOVERY_TARGET_LSN'"
    fi
    
    recovery_log "INFO" "Executing restore command: $restore_cmd"
    
    # Execute restore as postgres user
    if su-exec postgres $restore_cmd; then
        recovery_log "INFO" "Database restore completed successfully"
        return 0
    else
        recovery_log "ERROR" "Database restore failed"
        return 1
    fi
}

# Start PostgreSQL in recovery mode
start_recovery_postgresql() {
    recovery_log "INFO" "Starting PostgreSQL in recovery mode..."
    
    # Start PostgreSQL
    su-exec postgres postgres &
    local pg_pid=$!
    
    # Wait for PostgreSQL to start
    local wait_time=0
    local max_wait=300  # 5 minutes
    
    while [ $wait_time -lt $max_wait ]; do
        if su-exec postgres pg_isready -q 2>/dev/null; then
            recovery_log "INFO" "PostgreSQL started successfully in recovery mode"
            
            # Check if recovery completed
            if [ ! -f "$PGDATA/recovery.signal" ]; then
                recovery_log "INFO" "Recovery completed successfully"
                recovery_log "INFO" "Database is now available for normal operations"
            else
                recovery_log "INFO" "Recovery is in progress..."
            fi
            
            return 0
        fi
        
        sleep 5
        wait_time=$((wait_time + 5))
        
        # Check if PostgreSQL process is still running
        if ! kill -0 $pg_pid 2>/dev/null; then
            recovery_log "ERROR" "PostgreSQL process died during recovery"
            return 1
        fi
    done
    
    recovery_log "ERROR" "Timeout waiting for PostgreSQL to start"
    return 1
}

# Monitor recovery progress
monitor_recovery() {
    recovery_log "INFO" "Monitoring recovery progress..."
    
    local check_interval=10
    local last_lsn=""
    
    while [ -f "$PGDATA/recovery.signal" ]; do
        if su-exec postgres pg_isready -q 2>/dev/null; then
            # Get current recovery LSN
            local current_lsn=$(su-exec postgres psql -t -c "SELECT pg_last_wal_replay_lsn();" 2>/dev/null | tr -d ' ')
            
            if [ -n "$current_lsn" ] && [ "$current_lsn" != "$last_lsn" ]; then
                recovery_log "INFO" "Recovery progress - LSN: $current_lsn"
                last_lsn="$current_lsn"
            fi
        fi
        
        sleep $check_interval
    done
    
    recovery_log "INFO" "Recovery monitoring completed"
}

# Main recovery function
perform_recovery() {
    recovery_log "INFO" "=== Starting PostgreSQL Recovery Process ==="
    
    # Show recovery configuration
    recovery_log "INFO" "Recovery Configuration:"
    recovery_log "INFO" "  Mode: ${RECOVERY_MODE:-false}"
    recovery_log "INFO" "  Target Time: ${RECOVERY_TARGET_TIME:-latest}"
    recovery_log "INFO" "  Target Name: ${RECOVERY_TARGET_NAME:-none}"
    recovery_log "INFO" "  Target XID: ${RECOVERY_TARGET_XID:-none}"
    recovery_log "INFO" "  Target LSN: ${RECOVERY_TARGET_LSN:-none}"
    recovery_log "INFO" "  Target Inclusive: ${RECOVERY_TARGET_INCLUSIVE:-true}"
    recovery_log "INFO" "  Target Action: ${RECOVERY_TARGET_ACTION:-promote}"
    
    # Validate parameters
    if ! validate_recovery_params; then
        recovery_log "ERROR" "Recovery parameter validation failed"
        return 1
    fi
    
    # Setup rclone
    if ! setup_rclone; then
        recovery_log "ERROR" "Failed to setup rclone for recovery"
        return 1
    fi
    
    # Download backup repository
    if ! download_backup_repository; then
        recovery_log "ERROR" "Failed to download backup repository"
        return 1
    fi
    
    # List available backups
    list_available_backups
    
    # Find best backup for recovery
    local backup_label
    if ! backup_label=$(find_recovery_backup "$RECOVERY_TARGET_TIME"); then
        recovery_log "ERROR" "Failed to find suitable backup for recovery"
        return 1
    fi
    
    # Prepare data directory
    if ! prepare_data_directory; then
        recovery_log "ERROR" "Failed to prepare data directory"
        return 1
    fi
    
    # Perform restore
    if ! perform_restore "$backup_label"; then
        recovery_log "ERROR" "Database restore failed"
        return 1
    fi
    
    # Create recovery configuration
    if ! create_recovery_config; then
        recovery_log "ERROR" "Failed to create recovery configuration"
        return 1
    fi
    
    # Start PostgreSQL in recovery mode
    if ! start_recovery_postgresql; then
        recovery_log "ERROR" "Failed to start PostgreSQL in recovery mode"
        return 1
    fi
    
    # Monitor recovery progress in background
    monitor_recovery &
    
    recovery_log "INFO" "=== PostgreSQL Recovery Process Completed Successfully ==="
    return 0
}

# Handle script termination
cleanup_recovery() {
    recovery_log "INFO" "Recovery script terminated"
}

trap cleanup_recovery EXIT

# Main function
main() {
    # Create log directory
    mkdir -p "$(dirname "$RECOVERY_LOG_FILE")"
    
    if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
        show_recovery_usage
        exit 0
    fi
    
    if is_recovery_mode; then
        perform_recovery
    else
        recovery_log "INFO" "Recovery mode not enabled (RECOVERY_MODE != true)"
        return 0
    fi
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
