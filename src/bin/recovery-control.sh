#!/bin/bash

# Recovery Control Script
# This script provides control and information about recovery operations

set -e

# Source required modules
source /backup/src/lib/logging.sh
source /backup/src/lib/error-handling.sh
source /backup/src/lib/config.sh
source /backup/src/lib/environment.sh
source /backup/src/core/rclone.sh
source /backup/src/core/recovery.sh

RECOVERY_LOG_FILE="/backup/logs/recovery.log"

# Display usage information
show_usage() {
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Recovery Control Commands:"
    echo "  list-backups        List available backups from remote storage"
    echo "  download-repo       Download backup repository from remote storage"
    echo "  validate-target     Validate recovery target parameters"
    echo "  show-config         Show current recovery configuration"
    echo "  logs                Show recovery logs"
    echo "  test-connection     Test connection to remote storage"
    echo "  prepare-recovery    Prepare for recovery (download repo, validate)"
    echo ""
    echo "Options:"
    echo "  -f, --follow        Follow logs in real-time (with logs command)"
    echo "  -n, --lines N       Show last N lines of logs (default: 50)"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 list-backups              # List available backups"
    echo "  $0 validate-target           # Validate current recovery settings"
    echo "  $0 logs -n 100               # Show last 100 log lines"
    echo "  $0 test-connection           # Test remote storage connection"
    echo ""
}

# Test connection to remote storage
test_remote_connection() {
    echo "=== Testing Remote Storage Connection ==="
    
    # Setup rclone
    if ! setup_rclone; then
        echo "ERROR: Failed to setup rclone"
        return 1
    fi
    
    echo "Remote Name: $REMOTE_NAME"
    echo "Remote Path: ${RCLONE_REMOTE_PATH:-postgres-backups}"
    
    # Test basic connection
    echo "Testing basic connection..."
    if rclone lsd "${REMOTE_NAME}:" --config "$RCLONE_CONFIG_PATH" >/dev/null 2>&1; then
        echo "✅ Basic connection successful"
    else
        echo "❌ Basic connection failed"
        return 1
    fi
    
    # Test backup path
    local db_identifier=$(get_database_identifier)
    local remote_base_path="${RCLONE_REMOTE_PATH:-postgres-backups}/${db_identifier}"

    echo "Testing backup base path: ${REMOTE_NAME}:${remote_base_path}/"
    if rclone lsf "${REMOTE_NAME}:${remote_base_path}/" --config "$RCLONE_CONFIG_PATH" >/dev/null 2>&1; then
        echo "✅ Backup base path accessible"

        # Show directory structure
        echo ""
        echo "Available backup directories:"
        rclone lsd "${REMOTE_NAME}:${remote_base_path}/" --config "$RCLONE_CONFIG_PATH" 2>/dev/null || echo "No subdirectories found"

        # Check specific backup type directories
        echo ""
        echo "Checking backup type directories:"
        for backup_type in "full-backups" "incremental-backups" "differential-backups" "repository"; do
            local type_path="${remote_base_path}/${backup_type}"
            if rclone lsf "${REMOTE_NAME}:${type_path}/" --config "$RCLONE_CONFIG_PATH" >/dev/null 2>&1; then
                local file_count=$(rclone lsf "${REMOTE_NAME}:${type_path}/" --config "$RCLONE_CONFIG_PATH" | wc -l)
                echo "  ✅ $backup_type: $file_count files"
            else
                echo "  ❌ $backup_type: not found"
            fi
        done

        return 0
    else
        echo "❌ Backup base path not accessible or empty"
        return 1
    fi
}

# Download backup repository
download_repository() {
    echo "=== Downloading Backup Repository ==="
    
    # Setup rclone
    if ! setup_rclone; then
        echo "ERROR: Failed to setup rclone"
        return 1
    fi
    
    local db_identifier=$(get_database_identifier)
    local remote_repo_path="${RCLONE_REMOTE_PATH:-postgres-backups}/${db_identifier}/repository"
    local local_repo_path="/var/lib/pgbackrest"
    
    echo "Source: ${REMOTE_NAME}:${remote_repo_path}/"
    echo "Destination: $local_repo_path"
    
    # Check if remote repository exists
    if ! rclone lsf "${REMOTE_NAME}:${remote_repo_path}/" --config "$RCLONE_CONFIG_PATH" >/dev/null 2>&1; then
        echo "ERROR: Remote backup repository not found"
        return 1
    fi
    
    # Create local directory
    mkdir -p "$local_repo_path"
    chown postgres:postgres "$local_repo_path"
    
    # Download with progress
    echo "Downloading repository..."
    if rclone sync "${REMOTE_NAME}:${remote_repo_path}/" "$local_repo_path" \
        --config "$RCLONE_CONFIG_PATH" \
        --progress \
        --exclude="*.lock" \
        --exclude="*.tmp"; then
        
        echo "✅ Repository downloaded successfully"
        
        # Set permissions
        chown -R postgres:postgres "$local_repo_path"
        chmod -R 750 "$local_repo_path"
        
        # Show repository size
        local repo_size=$(du -sh "$local_repo_path" | cut -f1)
        echo "Repository size: $repo_size"
        
        return 0
    else
        echo "❌ Failed to download repository"
        return 1
    fi
}

# List available backups
list_remote_backups() {
    echo "=== Available Backups ==="
    
    # Download repository first if not exists
    if [ ! -d "/var/lib/pgbackrest" ] || [ -z "$(ls -A /var/lib/pgbackrest 2>/dev/null)" ]; then
        echo "Local repository not found. Downloading..."
        if ! download_repository; then
            echo "ERROR: Failed to download repository"
            return 1
        fi
    fi
    
    local stanza_name="${PGBACKREST_STANZA:-main}"
    
    echo "Stanza: $stanza_name"
    echo ""
    
    # List backups
    if su-exec postgres pgbackrest --stanza="$stanza_name" info 2>/dev/null; then
        echo ""
        echo "✅ Backup list completed"
        
        # Also show JSON format for detailed info
        echo ""
        echo "=== Detailed Backup Information ==="
        if command -v jq >/dev/null 2>&1; then
            su-exec postgres pgbackrest --stanza="$stanza_name" info --output=json 2>/dev/null | jq -r '
                .[] | .backup[] | 
                "Backup: \(.label)",
                "  Type: \(.type)",
                "  Start: \(.timestamp.start | strftime("%Y-%m-%d %H:%M:%S"))",
                "  Stop: \(.timestamp.stop | strftime("%Y-%m-%d %H:%M:%S"))",
                "  Size: \(.info.size // "N/A")",
                "  Database Size: \(.info.delta // "N/A")",
                ""
            ' 2>/dev/null || echo "Could not parse backup details"
        else
            echo "Install jq for detailed backup information"
        fi
        
        return 0
    else
        echo "❌ Could not list backups. Repository may be empty or corrupted."
        return 1
    fi
}

# Validate recovery target
validate_recovery_target() {
    echo "=== Validating Recovery Target ==="
    
    echo "Current Recovery Configuration:"
    echo "  RECOVERY_MODE: ${RECOVERY_MODE:-false}"
    echo "  RECOVERY_TARGET_TIME: ${RECOVERY_TARGET_TIME:-not set}"
    echo "  RECOVERY_TARGET_NAME: ${RECOVERY_TARGET_NAME:-not set}"
    echo "  RECOVERY_TARGET_XID: ${RECOVERY_TARGET_XID:-not set}"
    echo "  RECOVERY_TARGET_LSN: ${RECOVERY_TARGET_LSN:-not set}"
    echo "  RECOVERY_TARGET_INCLUSIVE: ${RECOVERY_TARGET_INCLUSIVE:-true}"
    echo "  RECOVERY_TARGET_ACTION: ${RECOVERY_TARGET_ACTION:-promote}"
    echo ""
    
    # Check if recovery mode is enabled
    if [ "${RECOVERY_MODE:-false}" != "true" ]; then
        echo "⚠️  Recovery mode is not enabled (RECOVERY_MODE != true)"
        echo "   To enable recovery mode, set RECOVERY_MODE=true"
        echo ""
    fi
    
    # Count recovery targets
    local target_count=0
    [ -n "$RECOVERY_TARGET_TIME" ] && target_count=$((target_count + 1))
    [ -n "$RECOVERY_TARGET_NAME" ] && target_count=$((target_count + 1))
    [ -n "$RECOVERY_TARGET_XID" ] && target_count=$((target_count + 1))
    [ -n "$RECOVERY_TARGET_LSN" ] && target_count=$((target_count + 1))
    
    if [ $target_count -eq 0 ]; then
        echo "ℹ️  No specific recovery target set - will recover to latest backup"
    elif [ $target_count -eq 1 ]; then
        echo "✅ Single recovery target specified"
        
        # Validate time format if specified
        if [ -n "$RECOVERY_TARGET_TIME" ]; then
            if date -d "$RECOVERY_TARGET_TIME" >/dev/null 2>&1; then
                echo "✅ Recovery target time format is valid"
                echo "   Target: $(date -d "$RECOVERY_TARGET_TIME")"
            else
                echo "❌ Invalid recovery target time format"
                echo "   Expected: 'YYYY-MM-DD HH:MM:SS'"
                return 1
            fi
        fi
    else
        echo "❌ Multiple recovery targets specified"
        echo "   Please specify only one recovery target"
        return 1
    fi
    
    # Validate action
    case "${RECOVERY_TARGET_ACTION:-promote}" in
        promote|pause|shutdown)
            echo "✅ Recovery target action is valid: ${RECOVERY_TARGET_ACTION:-promote}"
            ;;
        *)
            echo "❌ Invalid recovery target action: ${RECOVERY_TARGET_ACTION}"
            echo "   Valid actions: promote, pause, shutdown"
            return 1
            ;;
    esac
    
    echo ""
    echo "✅ Recovery target validation completed"
    return 0
}

# Show recovery configuration
show_recovery_config() {
    echo "=== Recovery Configuration ==="
    echo ""
    echo "Environment Variables:"
    echo "  RECOVERY_MODE=${RECOVERY_MODE:-false}"
    echo "  RECOVERY_TARGET_TIME=${RECOVERY_TARGET_TIME:-not set}"
    echo "  RECOVERY_TARGET_NAME=${RECOVERY_TARGET_NAME:-not set}"
    echo "  RECOVERY_TARGET_XID=${RECOVERY_TARGET_XID:-not set}"
    echo "  RECOVERY_TARGET_LSN=${RECOVERY_TARGET_LSN:-not set}"
    echo "  RECOVERY_TARGET_INCLUSIVE=${RECOVERY_TARGET_INCLUSIVE:-true}"
    echo "  RECOVERY_TARGET_ACTION=${RECOVERY_TARGET_ACTION:-promote}"
    echo ""
    echo "Backup Configuration:"
    echo "  PGBACKREST_STANZA=${PGBACKREST_STANZA:-main}"
    echo "  RCLONE_REMOTE_PATH=${RCLONE_REMOTE_PATH:-postgres-backups}"
    echo "  Database Identifier: $(get_database_identifier)"
    echo ""
    echo "File Paths:"
    echo "  Recovery Log: $RECOVERY_LOG_FILE"
    echo "  PostgreSQL Data: ${PGDATA:-/var/lib/postgresql/data}"
    echo "  pgBackRest Repository: /var/lib/pgbackrest"
    echo ""
}

# Show recovery logs
show_recovery_logs() {
    local lines=50
    local follow=false
    
    # Parse options
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--follow)
                follow=true
                shift
                ;;
            -n|--lines)
                lines="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                return 1
                ;;
        esac
    done
    
    if [ ! -f "$RECOVERY_LOG_FILE" ]; then
        echo "Recovery log file not found: $RECOVERY_LOG_FILE"
        return 1
    fi
    
    if [ "$follow" = true ]; then
        echo "Following recovery logs (Ctrl+C to stop)..."
        tail -f "$RECOVERY_LOG_FILE"
    else
        echo "Last $lines lines of recovery logs:"
        tail -n "$lines" "$RECOVERY_LOG_FILE"
    fi
}

# Prepare for recovery
prepare_recovery() {
    echo "=== Preparing for Recovery ==="
    
    # Validate configuration
    echo "1. Validating recovery configuration..."
    if ! validate_recovery_target; then
        echo "❌ Recovery configuration validation failed"
        return 1
    fi
    
    # Test remote connection
    echo "2. Testing remote storage connection..."
    if ! test_remote_connection; then
        echo "❌ Remote storage connection failed"
        return 1
    fi
    
    # Download repository
    echo "3. Downloading backup repository..."
    if ! download_repository; then
        echo "❌ Repository download failed"
        return 1
    fi
    
    # List available backups
    echo "4. Listing available backups..."
    if ! list_remote_backups; then
        echo "❌ Could not list backups"
        return 1
    fi
    
    echo ""
    echo "✅ Recovery preparation completed successfully"
    echo ""
    echo "To start recovery, restart the container with RECOVERY_MODE=true"
    return 0
}

# Main function
main() {
    local command="$1"
    shift || true
    
    case "$command" in
        list-backups)
            list_remote_backups
            ;;
        download-repo)
            download_repository
            ;;
        validate-target)
            validate_recovery_target
            ;;
        show-config)
            show_recovery_config
            ;;
        logs)
            show_recovery_logs "$@"
            ;;
        test-connection)
            test_remote_connection
            ;;
        prepare-recovery)
            prepare_recovery
            ;;
        -h|--help|help|"")
            show_usage
            ;;
        *)
            echo "Unknown command: $command"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
