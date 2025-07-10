#!/bin/bash

# Setup cron jobs for PostgreSQL backup system

source /backup/scripts/backup-functions.sh

setup_cron() {
    log "INFO" "Setting up cron jobs for backup system..."
    
    # Get backup schedule from environment variable
    local backup_schedule="${BASE_BACKUP_SCHEDULE:-0 3 * * *}"
    
    log "INFO" "Backup schedule: $backup_schedule"
    
    # Create cron job entry
    local cron_entry="$backup_schedule /backup/scripts/backup.sh >> /backup/logs/backup.log 2>&1"
    
    # Create crontab for postgres user
    log "INFO" "Creating crontab for postgres user..."
    
    # Create temporary crontab file
    local temp_crontab=$(mktemp)
    
    # Add environment variables to crontab
    cat > "$temp_crontab" << EOF
# Environment variables for backup scripts
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=${POSTGRES_DB:-}
PGDATA=${PGDATA:-/var/lib/postgresql/data}
PGHOST=${PGHOST:-/var/run/postgresql}
PGPORT=${PGPORT:-5432}
RCLONE_CONF_BASE64=${RCLONE_CONF_BASE64}
RCLONE_REMOTE_NAME=${RCLONE_REMOTE_NAME:-}
RCLONE_REMOTE_PATH=${RCLONE_REMOTE_PATH:-postgres-backups}
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-3}
PGBACKREST_STANZA=${PGBACKREST_STANZA:-main}
PGBACKREST_CONFIG=/etc/pgbackrest/pgbackrest.conf

# Backup job
${cron_entry}
EOF
    
    # Create crontab directory for postgres user if it doesn't exist
    mkdir -p /var/spool/cron/crontabs

    # Install crontab directly to the crontabs directory
    if ! cp "$temp_crontab" "/var/spool/cron/crontabs/postgres"; then
        log "ERROR" "Failed to install crontab for postgres user"
        rm -f "$temp_crontab"
        return 1
    fi

    # Set proper permissions for crontab file
    chown postgres:postgres "/var/spool/cron/crontabs/postgres"
    chmod 600 "/var/spool/cron/crontabs/postgres"

    # Clean up temporary file
    rm -f "$temp_crontab"

    log "INFO" "Crontab installed successfully for postgres user"

    # Verify crontab installation
    log "INFO" "Verifying crontab installation..."
    if [ -f "/var/spool/cron/crontabs/postgres" ] && grep -q "/backup/scripts/backup.sh" "/var/spool/cron/crontabs/postgres"; then
        log "INFO" "Crontab verification successful"
    else
        log "ERROR" "Crontab verification failed"
        return 1
    fi
    
    return 0
}

start_cron_daemon() {
    log "INFO" "Starting cron daemon..."
    
    # Start crond in the background
    if ! crond -b -l 8; then
        log "ERROR" "Failed to start cron daemon"
        return 1
    fi
    
    log "INFO" "Cron daemon started successfully"
    
    # Verify cron daemon is running
    if pgrep crond > /dev/null; then
        log "INFO" "Cron daemon is running"
    else
        log "ERROR" "Cron daemon is not running"
        return 1
    fi
    
    return 0
}

# Main function
main() {
    log "INFO" "=== Setting up cron backup system ==="
    
    # Setup cron jobs
    if ! setup_cron; then
        log "ERROR" "Failed to setup cron jobs"
        exit 1
    fi
    
    # Start cron daemon
    if ! start_cron_daemon; then
        log "ERROR" "Failed to start cron daemon"
        exit 1
    fi
    
    log "INFO" "=== Cron backup system setup completed ==="
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
