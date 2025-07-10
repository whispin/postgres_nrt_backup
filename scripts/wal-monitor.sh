#!/bin/bash

# WAL file growth monitoring and automatic incremental backup
# This script monitors WAL file growth and triggers incremental backups when threshold is reached

set -e

source /backup/scripts/backup-functions.sh

# Configuration
WAL_MONITOR_INTERVAL=${WAL_MONITOR_INTERVAL:-60}  # Check interval in seconds
WAL_GROWTH_THRESHOLD=${WAL_GROWTH_THRESHOLD:-"100MB"}  # Default threshold
WAL_STATE_FILE="/backup/logs/wal-monitor.state"
WAL_LOG_FILE="/backup/logs/wal-monitor.log"

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

# Get current WAL directory size
get_wal_size() {
    local wal_dir="$PGDATA/pg_wal"
    if [ -d "$wal_dir" ]; then
        du -sb "$wal_dir" 2>/dev/null | cut -f1 || echo "0"
    else
        echo "0"
    fi
}

# Get WAL LSN (Log Sequence Number) for more precise tracking
get_current_lsn() {
    local lsn=$(su-exec postgres psql -t -c "SELECT pg_current_wal_lsn();" 2>/dev/null | tr -d ' ')
    echo "$lsn"
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

# Calculate WAL growth since last check
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

# Load state from file
load_state() {
    if [ -f "$WAL_STATE_FILE" ]; then
        source "$WAL_STATE_FILE"
    else
        # Initialize state
        LAST_BACKUP_TIME=""
        LAST_BACKUP_LSN=""
        LAST_CHECK_LSN=""
        ACCUMULATED_WAL_GROWTH=0
    fi
}

# Save state to file
save_state() {
    cat > "$WAL_STATE_FILE" << EOF
LAST_BACKUP_TIME="$LAST_BACKUP_TIME"
LAST_BACKUP_LSN="$LAST_BACKUP_LSN"
LAST_CHECK_LSN="$LAST_CHECK_LSN"
ACCUMULATED_WAL_GROWTH=$ACCUMULATED_WAL_GROWTH
EOF
}

# Log with timestamp to WAL monitor log
wal_log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$WAL_LOG_FILE"
    # Also log to main backup log
    log "$level" "WAL-MONITOR: $message"
}

# Check if incremental backup is needed
check_backup_needed() {
    local current_lsn="$1"
    local threshold_bytes="$2"
    
    # Calculate growth since last check
    local growth=$(calculate_wal_growth "$current_lsn" "$LAST_CHECK_LSN")
    
    # Add to accumulated growth
    ACCUMULATED_WAL_GROWTH=$(( ACCUMULATED_WAL_GROWTH + growth ))
    
    wal_log "INFO" "Current LSN: $current_lsn, Growth since last check: $growth bytes"
    wal_log "INFO" "Accumulated WAL growth: $ACCUMULATED_WAL_GROWTH bytes, Threshold: $threshold_bytes bytes"
    
    if [ "$ACCUMULATED_WAL_GROWTH" -ge "$threshold_bytes" ]; then
        return 0  # Backup needed
    else
        return 1  # No backup needed
    fi
}

# Perform incremental backup and reset counters
perform_wal_triggered_backup() {
    local current_lsn="$1"

    wal_log "INFO" "WAL growth threshold reached. Starting incremental backup..."

    # Check if full backup exists first
    if ! check_full_backup_exists; then
        wal_log "WARN" "No full backup found. Performing full backup first..."
        if perform_full_backup; then
            wal_log "INFO" "Full backup completed successfully"
            # Reset counters after full backup
            LAST_BACKUP_TIME=$(date '+%Y-%m-%d %H:%M:%S')
            LAST_BACKUP_LSN="$current_lsn"
            ACCUMULATED_WAL_GROWTH=0
            return 0
        else
            wal_log "ERROR" "Failed to perform prerequisite full backup"
            return 1
        fi
    fi

    # Perform incremental backup
    if perform_incremental_backup; then
        wal_log "INFO" "Incremental backup completed successfully"

        # Reset counters
        LAST_BACKUP_TIME=$(date '+%Y-%m-%d %H:%M:%S')
        LAST_BACKUP_LSN="$current_lsn"
        ACCUMULATED_WAL_GROWTH=0

        # Upload to remote storage if configured
        if [ -n "$REMOTE_NAME" ] && [ -f "$RCLONE_CONFIG_PATH" ]; then
            wal_log "INFO" "Uploading incremental backup to remote storage..."
            if upload_incremental_backup; then
                wal_log "INFO" "Incremental backup uploaded successfully"
            else
                wal_log "ERROR" "Failed to upload incremental backup"
            fi
        fi

        return 0
    else
        wal_log "ERROR" "Incremental backup failed"
        return 1
    fi
}

# Upload incremental backup to remote storage
upload_incremental_backup() {
    local stanza_name="${PGBACKREST_STANZA:-main}"
    local db_identifier=$(get_database_identifier)
    local remote_repo_path="${RCLONE_REMOTE_PATH:-postgres-backups}/${db_identifier}/repository"
    local remote_incr_path="${RCLONE_REMOTE_PATH:-postgres-backups}/${db_identifier}/incremental-backups"

    # Get latest incremental backup info
    local backup_info=$(su-exec postgres pgbackrest --stanza="$stanza_name" info --output=json 2>/dev/null | jq -r '.[] | .backup[] | select(.type=="incr") | .label' | tail -1)

    if [ -n "$backup_info" ]; then
        wal_log "INFO" "Uploading incremental backup: $backup_info"

        # Create remote directories
        if ! rclone mkdir "${REMOTE_NAME}:${remote_repo_path}/" --config "$RCLONE_CONFIG_PATH"; then
            wal_log "WARN" "Failed to create remote repository directory (may already exist)"
        fi

        if ! rclone mkdir "${REMOTE_NAME}:${remote_incr_path}/" --config "$RCLONE_CONFIG_PATH"; then
            wal_log "WARN" "Failed to create remote incremental directory (may already exist)"
        fi

        # Upload pgBackRest repository to common repository directory
        local backup_path="/var/lib/pgbackrest"
        if [ -d "$backup_path" ]; then
            if rclone sync "$backup_path" "${REMOTE_NAME}:${remote_repo_path}" --config "$RCLONE_CONFIG_PATH" --exclude="*.lock" --exclude="*.tmp"; then
                wal_log "INFO" "Incremental backup repository synced successfully"

                # Create and upload metadata to incremental-specific directory
                local timestamp=$(date '+%Y%m%d_%H%M%S')
                local metadata_file="/tmp/wal_incremental_backup_${timestamp}.json"

                cat > "$metadata_file" << EOF
{
    "backup_type": "incr",
    "stanza": "$stanza_name",
    "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "database_identifier": "$db_identifier",
    "backup_label": "$backup_info",
    "triggered_by": "wal_monitor",
    "wal_threshold": "$WAL_GROWTH_THRESHOLD"
}
EOF

                if rclone copy "$metadata_file" "${REMOTE_NAME}:${remote_incr_path}/" --config "$RCLONE_CONFIG_PATH"; then
                    wal_log "INFO" "Incremental backup metadata uploaded successfully"
                else
                    wal_log "WARN" "Failed to upload incremental backup metadata"
                fi

                rm -f "$metadata_file"
                return 0
            else
                wal_log "ERROR" "Failed to sync incremental backup repository"
                return 1
            fi
        fi
    else
        wal_log "WARN" "No incremental backup found to upload"
        return 1
    fi
}

# Main monitoring loop
monitor_wal_growth() {
    wal_log "INFO" "Starting WAL growth monitoring"
    wal_log "INFO" "Threshold: $WAL_GROWTH_THRESHOLD, Check interval: ${WAL_MONITOR_INTERVAL}s"
    
    # Parse threshold to bytes
    local threshold_bytes
    if ! threshold_bytes=$(parse_size_to_bytes "$WAL_GROWTH_THRESHOLD"); then
        wal_log "ERROR" "Invalid WAL_GROWTH_THRESHOLD format: $WAL_GROWTH_THRESHOLD"
        return 1
    fi
    
    wal_log "INFO" "Threshold in bytes: $threshold_bytes"
    
    # Load previous state
    load_state
    
    while true; do
        # Check if PostgreSQL is ready
        if ! wait_for_postgres 10; then
            wal_log "WARN" "PostgreSQL not ready, skipping this check"
            sleep "$WAL_MONITOR_INTERVAL"
            continue
        fi
        
        # Get current LSN
        local current_lsn=$(get_current_lsn)
        if [ -z "$current_lsn" ] || [ "$current_lsn" = "" ]; then
            wal_log "WARN" "Could not get current LSN, skipping this check"
            sleep "$WAL_MONITOR_INTERVAL"
            continue
        fi
        
        # Check if backup is needed
        if check_backup_needed "$current_lsn" "$threshold_bytes"; then
            if perform_wal_triggered_backup "$current_lsn"; then
                wal_log "INFO" "WAL-triggered backup completed successfully"
            else
                wal_log "ERROR" "WAL-triggered backup failed"
            fi
        fi
        
        # Update last check LSN
        LAST_CHECK_LSN="$current_lsn"
        
        # Save state
        save_state
        
        # Wait for next check
        sleep "$WAL_MONITOR_INTERVAL"
    done
}

# Handle script termination
cleanup() {
    wal_log "INFO" "WAL monitor shutting down..."
    save_state
}

trap cleanup EXIT

# Main function
main() {
    # Ensure required tools are available
    if ! command -v bc >/dev/null 2>&1; then
        wal_log "ERROR" "bc command not found. Please install bc package."
        exit 1
    fi
    
    # Create log directory
    mkdir -p "$(dirname "$WAL_LOG_FILE")"
    
    # Start monitoring
    monitor_wal_growth
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
