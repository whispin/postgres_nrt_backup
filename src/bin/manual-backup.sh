#!/bin/bash

# Manual backup trigger script
# This script allows manual execution of backup operations

set -e

# Source all required modules
source /backup/src/lib/logging.sh
source /backup/src/lib/error-handling.sh
source /backup/src/lib/config.sh
source /backup/src/lib/environment.sh
source /backup/src/core/rclone.sh
source /backup/src/core/pgbackrest.sh
source /backup/src/core/backup.sh

# Display usage information
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Manual backup trigger for PostgreSQL"
    echo ""
    echo "Options:"
    echo "  -h, --help          Show this help message"
    echo "  -f, --full          Perform full backup (default)"
    echo "  -i, --incremental   Perform incremental backup"
    echo "  -d, --diff          Perform differential backup"
    echo "  -c, --check         Check backup status and configuration"
    echo "  -l, --list          List available backups"
    echo "  -v, --verbose       Enable verbose output"
    echo ""
    echo "Examples:"
    echo "  $0                  # Perform full backup"
    echo "  $0 --full           # Perform full backup"
    echo "  $0 --incremental    # Perform incremental backup"
    echo "  $0 --check          # Check backup configuration"
    echo "  $0 --list           # List available backups"
    echo ""
}

# Parse command line arguments
BACKUP_TYPE="full"
VERBOSE=false
CHECK_ONLY=false
LIST_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -f|--full)
            BACKUP_TYPE="full"
            shift
            ;;
        -i|--incremental)
            BACKUP_TYPE="incr"
            shift
            ;;
        -d|--diff)
            BACKUP_TYPE="diff"
            shift
            ;;
        -c|--check)
            CHECK_ONLY=true
            shift
            ;;
        -l|--list)
            LIST_ONLY=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Enable verbose output if requested
if [ "$VERBOSE" = true ]; then
    set -x
fi

# Check backup configuration
check_backup_config() {
    log "INFO" "=== Checking Backup Configuration ==="
    
    # Check PostgreSQL connection
    if ! wait_for_postgres 30; then
        log "ERROR" "PostgreSQL is not available"
        return 1
    fi
    
    # Check pgBackRest configuration
    local stanza="${PGBACKREST_STANZA:-main}"
    log "INFO" "Using stanza: $stanza"
    
    # Check if stanza exists
    if ! pgbackrest --stanza="$stanza" check; then
        log "WARN" "Stanza check failed, attempting to create stanza..."
        if ! pgbackrest --stanza="$stanza" stanza-create; then
            log "ERROR" "Failed to create stanza"
            return 1
        fi
        log "INFO" "Stanza created successfully"
    fi
    
    # Check rclone configuration
    if [ -f "$RCLONE_CONFIG_PATH" ]; then
        log "INFO" "Rclone configuration found"
        if command -v rclone >/dev/null 2>&1; then
            log "INFO" "Rclone version: $(rclone version | head -1)"
        fi
    else
        log "WARN" "Rclone configuration not found"
    fi
    
    log "INFO" "=== Configuration Check Completed ==="
    return 0
}

# List available backups
list_backups() {
    log "INFO" "=== Available Backups ==="
    
    local stanza="${PGBACKREST_STANZA:-main}"
    
    # List pgBackRest backups
    log "INFO" "pgBackRest backups:"
    if pgbackrest --stanza="$stanza" info 2>/dev/null; then
        log "INFO" "pgBackRest backup list completed"
    else
        log "WARN" "No pgBackRest backups found or stanza not initialized"
    fi
    
    # List local backup files
    log "INFO" "Local backup files:"
    if [ -d "/backup/local" ]; then
        find /backup/local -type f -name "*.backup" -o -name "*.sql" -o -name "*.gz" 2>/dev/null | head -10 || log "INFO" "No local backup files found"
    else
        log "INFO" "Local backup directory not found"
    fi
    
    log "INFO" "=== Backup List Completed ==="
}

# Perform manual backup
perform_manual_backup() {
    log "INFO" "=== Starting Manual Backup Process ==="
    log "INFO" "Backup type: $BACKUP_TYPE"
    
    # Check configuration first
    if ! check_backup_config; then
        log "ERROR" "Configuration check failed"
        return 1
    fi
    
    # Perform the backup based on type
    case $BACKUP_TYPE in
        "full")
            log "INFO" "Performing full backup..."
            if ! perform_full_backup; then
                log "ERROR" "Full backup failed"
                return 1
            fi
            ;;
        "incr")
            log "INFO" "Performing incremental backup..."
            if ! perform_incremental_backup; then
                log "ERROR" "Incremental backup failed"
                return 1
            fi
            ;;
        "diff")
            log "INFO" "Performing differential backup..."
            if ! perform_differential_backup; then
                log "ERROR" "Differential backup failed"
                return 1
            fi
            ;;
        *)
            log "ERROR" "Unknown backup type: $BACKUP_TYPE"
            return 1
            ;;
    esac
    
    log "INFO" "=== Manual Backup Process Completed Successfully ==="
    return 0
}

# Main function
main() {
    log "INFO" "=== Manual Backup Script Started ==="
    
    # Initialize environment first
    if ! initialize_environment; then
        log "ERROR" "Failed to initialize environment"
        exit 1
    fi
    
    if [ "$CHECK_ONLY" = true ]; then
        check_backup_config
        exit $?
    elif [ "$LIST_ONLY" = true ]; then
        list_backups
        exit $?
    else
        perform_manual_backup
        exit $?
    fi
}

# Handle script termination
cleanup() {
    log "INFO" "Manual backup script terminated"
}

trap cleanup EXIT

# Run main function
main "$@"
