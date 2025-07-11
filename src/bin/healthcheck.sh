#!/bin/bash

# Health check script for PostgreSQL backup container

# Source required modules
source /backup/src/lib/logging.sh
source /backup/src/lib/error-handling.sh
source /backup/src/lib/environment.sh

# Check PostgreSQL health
check_postgresql() {
    if ! pg_isready -U "$POSTGRES_USER" -d "${POSTGRES_DB:-postgres}" -q; then
        log "ERROR" "PostgreSQL is not ready"
        return 1
    fi
    return 0
}

# Check cron daemon
check_cron() {
    if ! pgrep crond > /dev/null; then
        log "ERROR" "Cron daemon is not running"
        return 1
    fi
    return 0
}

# Check rclone configuration
check_rclone_config() {
    if [[ ! -f "$RCLONE_CONFIG_PATH" ]]; then
        log "ERROR" "Rclone configuration file not found"
        return 1
    fi
    return 0
}

# Check backup logs
check_backup_logs() {
    if [[ ! -f "/backup/logs/backup.log" ]]; then
        log "ERROR" "Backup log file not found"
        return 1
    fi
    return 0
}

# Main health check
main() {
    local exit_code=0
    
    echo "=== PostgreSQL Backup Container Health Check ==="
    
    # Check PostgreSQL
    if check_postgresql; then
        echo "✓ PostgreSQL: OK"
    else
        echo "✗ PostgreSQL: FAILED"
        exit_code=1
    fi
    
    # Check cron daemon
    if check_cron; then
        echo "✓ Cron daemon: OK"
    else
        echo "✗ Cron daemon: FAILED"
        exit_code=1
    fi
    
    # Check rclone configuration
    if check_rclone_config; then
        echo "✓ Rclone config: OK"
    else
        echo "✗ Rclone config: FAILED"
        exit_code=1
    fi
    
    # Check backup logs
    if check_backup_logs; then
        echo "✓ Backup logs: OK"
    else
        echo "✗ Backup logs: FAILED"
        exit_code=1
    fi
    
    if [[ $exit_code -eq 0 ]]; then
        echo "=== Overall health: HEALTHY ==="
    else
        echo "=== Overall health: UNHEALTHY ==="
    fi
    
    exit $exit_code
}

main "$@"
