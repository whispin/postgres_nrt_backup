#!/bin/bash

# Incremental Backup Script for Cron Jobs
# This script performs scheduled incremental backups

set -e

# Source required modules
source /backup/src/lib/logging.sh
source /backup/src/lib/error-handling.sh
source /backup/src/lib/config.sh
source /backup/src/lib/environment.sh
source /backup/src/core/rclone.sh
source /backup/src/core/pgbackrest.sh
source /backup/src/core/backup.sh

# Log file for incremental backup operations
INCREMENTAL_LOG_FILE="/backup/logs/incremental-backup.log"

# Incremental backup log function
incremental_log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] INCREMENTAL: $message" | tee -a "$INCREMENTAL_LOG_FILE"
    # Also log to main backup log
    log "$level" "INCREMENTAL: $message"
}

# Check if there are WAL changes since last backup
check_wal_changes() {
    incremental_log "INFO" "Checking for WAL changes since last backup..."

    # Get current WAL LSN
    local current_lsn=$(su-exec postgres psql -t -c "SELECT pg_current_wal_lsn();" 2>/dev/null | tr -d ' ')

    if [ -z "$current_lsn" ]; then
        incremental_log "ERROR" "Failed to get current WAL LSN"
        return 1
    fi

    incremental_log "INFO" "Current WAL LSN: $current_lsn"

    # Check WAL state file for last backup LSN
    local wal_state_file="/backup/logs/wal-monitor.state"
    local last_backup_lsn=""

    if [ -f "$wal_state_file" ]; then
        source "$wal_state_file"
        last_backup_lsn="$LAST_BACKUP_LSN"
    fi

    # If no previous backup LSN, allow backup
    if [ -z "$last_backup_lsn" ]; then
        incremental_log "INFO" "No previous backup LSN found, backup should proceed"
        return 0
    fi

    incremental_log "INFO" "Last backup LSN: $last_backup_lsn"

    # Compare LSNs to check for changes
    if [ "$current_lsn" = "$last_backup_lsn" ]; then
        incremental_log "INFO" "No WAL changes detected since last backup (LSN: $current_lsn)"
        return 1
    fi

    # Calculate WAL growth
    local wal_growth=$(calculate_wal_growth "$last_backup_lsn" "$current_lsn")

    if [ $? -eq 0 ] && [ -n "$wal_growth" ]; then
        incremental_log "INFO" "WAL changes detected: ${wal_growth} bytes since last backup"

        # Check if growth is significant (configurable minimum to avoid tiny changes)
        local min_growth_str="${MIN_WAL_GROWTH_FOR_BACKUP:-1MB}"
        local min_growth=$(parse_size_to_bytes "$min_growth_str")

        if [ "$wal_growth" -lt "$min_growth" ]; then
            incremental_log "INFO" "WAL growth (${wal_growth} bytes) is below minimum threshold (${min_growth} bytes / ${min_growth_str}), skipping backup"
            return 1
        fi

        incremental_log "INFO" "Significant WAL changes detected (${wal_growth} bytes), backup should proceed"
        return 0
    else
        incremental_log "WARN" "Could not calculate WAL growth, assuming changes exist"
        return 0
    fi
}

# Check if incremental backup should run
should_run_incremental_backup() {
    incremental_log "INFO" "Checking if incremental backup should run..."

    # Check if PostgreSQL is ready
    if ! wait_for_postgres 30; then
        incremental_log "ERROR" "PostgreSQL is not ready for incremental backup"
        return 1
    fi

    # Check for WAL changes first
    if ! check_wal_changes; then
        incremental_log "INFO" "No significant WAL changes detected, skipping incremental backup"
        return 1
    fi

    # Check if WAL monitor is enabled and recently triggered a backup
    if [ "${ENABLE_WAL_MONITOR:-true}" = "true" ]; then
        local wal_state_file="/backup/logs/wal-monitor.state"

        if [ -f "$wal_state_file" ]; then
            source "$wal_state_file"

            # Check if WAL monitor triggered a backup recently (within last hour)
            if [ -n "$LAST_BACKUP_TIME" ]; then
                local last_backup_epoch=$(date -d "$LAST_BACKUP_TIME" +%s 2>/dev/null || echo 0)
                local current_epoch=$(date +%s)
                local time_diff=$((current_epoch - last_backup_epoch))

                # If WAL monitor triggered backup within last hour, skip cron backup
                if [ $time_diff -lt 3600 ]; then
                    incremental_log "INFO" "WAL monitor triggered backup recently ($LAST_BACKUP_TIME), skipping cron incremental backup"
                    return 1
                fi
            fi
        fi
    fi

    incremental_log "INFO" "Incremental backup should proceed"
    return 0
}

# Perform scheduled incremental backup
perform_scheduled_incremental_backup() {
    incremental_log "INFO" "Starting scheduled incremental backup..."
    
    # Perform incremental backup (this will auto-create full backup if needed)
    if perform_incremental_backup; then
        incremental_log "INFO" "Scheduled incremental backup completed successfully"
        
        # Update WAL monitor state if it exists
        local wal_state_file="/backup/logs/wal-monitor.state"
        if [ -f "$wal_state_file" ]; then
            # Get current LSN
            local current_lsn=$(su-exec postgres psql -t -c "SELECT pg_current_wal_lsn();" 2>/dev/null | tr -d ' ')
            
            if [ -n "$current_lsn" ]; then
                # Update WAL monitor state to prevent duplicate backups
                cat > "$wal_state_file" << EOF
LAST_BACKUP_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
LAST_BACKUP_LSN="$current_lsn"
LAST_CHECK_LSN="$current_lsn"
ACCUMULATED_WAL_GROWTH=0
BACKUP_TRIGGERED_BY="cron_incremental"
EOF
                incremental_log "INFO" "Updated WAL monitor state after cron incremental backup"
            fi
        fi
        
        return 0
    else
        incremental_log "ERROR" "Scheduled incremental backup failed"
        return 1
    fi
}

# Cleanup old incremental backup logs
cleanup_incremental_logs() {
    local retention_days="${BACKUP_RETENTION_DAYS:-3}"
    
    if [ -f "$INCREMENTAL_LOG_FILE" ]; then
        # Keep only recent log entries (last retention_days worth)
        local temp_log=$(mktemp)
        local cutoff_date=$(date -d "$retention_days days ago" '+%Y-%m-%d')
        
        # Extract recent log entries
        grep -E "^\[([0-9]{4}-[0-9]{2}-[0-9]{2})" "$INCREMENTAL_LOG_FILE" | \
        while IFS= read -r line; do
            local log_date=$(echo "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
            if [[ "$log_date" > "$cutoff_date" ]] || [[ "$log_date" = "$cutoff_date" ]]; then
                echo "$line" >> "$temp_log"
            fi
        done
        
        # Replace log file if temp file has content
        if [ -s "$temp_log" ]; then
            mv "$temp_log" "$INCREMENTAL_LOG_FILE"
            incremental_log "INFO" "Cleaned up old incremental backup log entries"
        else
            rm -f "$temp_log"
        fi
    fi
}

# Main function
main() {
    # Create log directory
    mkdir -p "$(dirname "$INCREMENTAL_LOG_FILE")"
    
    incremental_log "INFO" "=== Starting Scheduled Incremental Backup ==="
    
    # Initialize environment first
    if ! initialize_environment; then
        incremental_log "ERROR" "Failed to initialize environment"
        exit 1
    fi
    
    # Check if backup should run
    if ! should_run_incremental_backup; then
        incremental_log "INFO" "Incremental backup skipped"
        exit 0
    fi
    
    # Perform incremental backup
    if perform_scheduled_incremental_backup; then
        incremental_log "INFO" "Scheduled incremental backup process completed successfully"
        
        # Cleanup old logs
        cleanup_incremental_logs
        
        exit 0
    else
        incremental_log "ERROR" "Scheduled incremental backup process failed"
        exit 1
    fi
}

# Handle script termination
cleanup() {
    incremental_log "INFO" "Incremental backup script terminated"
}

trap cleanup EXIT

# Run main function
main "$@"
