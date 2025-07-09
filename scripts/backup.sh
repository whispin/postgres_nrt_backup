#!/bin/bash

# PostgreSQL Backup Script using pgbackrest and rclone
# This script performs full backups and uploads them to remote storage

set -e

# Source backup functions
source /backup/scripts/backup-functions.sh

# Main backup function
main() {
    log "INFO" "=== Starting PostgreSQL Backup Process ==="
    
    # Check environment variables
    if ! check_env; then
        log "ERROR" "Environment check failed"
        exit 1
    fi
    
    # Setup rclone
    if ! setup_rclone; then
        log "ERROR" "Rclone setup failed"
        exit 1
    fi
    
    # Wait for PostgreSQL to be ready
    if ! wait_for_postgres 60; then
        log "ERROR" "PostgreSQL is not ready"
        exit 1
    fi
    
    # Perform full backup
    if ! perform_full_backup; then
        log "ERROR" "Backup process failed"
        exit 1
    fi
    
    log "INFO" "=== PostgreSQL Backup Process Completed Successfully ==="
}

# Handle script termination
cleanup() {
    log "INFO" "Backup script terminated"
}

trap cleanup EXIT

# Run main function
main "$@"
