#!/bin/bash
set -e

source /backup/scripts/backup-functions.sh

# Initialize backup system
initialize_backup_system() {
    log "INFO" "=== Initializing PostgreSQL Backup System ==="

    # Create log directory and file, and set permissions
    log "INFO" "Creating necessary directories..."
    mkdir -p /backup/logs
    touch /backup/logs/backup.log
    chown -R postgres:postgres /backup
    log "INFO" "Backup directories created and permissions set"

    # Export environment variables to /etc/environment for postgres user access
    log "INFO" "Exporting environment variables for postgres user access..."
    # Filter and properly format environment variables for /etc/environment
    printenv | grep -v "no_proxy" | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' | while IFS='=' read -r name value; do
        # Escape special characters in the value and ensure proper quoting
        printf 'export %s="%s"\n' "$name" "${value//\"/\\\"}"
    done > /etc/environment
    log "INFO" "Environment variables exported to /etc/environment"

    # Check environment variables
    log "INFO" "Checking environment variables..."
    if ! check_env; then
        log "ERROR" "Environment check failed"
        return 1
    fi

    # Setup rclone
    log "INFO" "Setting up rclone..."
    if ! setup_rclone; then
        log "ERROR" "Rclone setup failed"
        return 1
    fi

    log "INFO" "=== Backup System Initialization Completed ==="
    return 0
}

# Start PostgreSQL and wait for it to be ready
start_postgresql() {
    log "INFO" "Starting PostgreSQL..."

    # Start PostgreSQL in background
    /usr/local/bin/docker-entrypoint.sh postgres &

    # Wait for PostgreSQL to be ready
    log "INFO" "Waiting for PostgreSQL to start..."
    if ! wait_for_postgres 120; then
        log "ERROR" "PostgreSQL failed to start"
        return 1
    fi

    log "INFO" "PostgreSQL is ready"
    return 0
}

# Setup backup system
setup_backup_system() {
    log "INFO" "Setting up backup system..."

    # Setup cron jobs
    if ! /backup/scripts/setup-cron.sh; then
        log "ERROR" "Failed to setup cron jobs"
        return 1
    fi

    log "INFO" "Backup system setup completed"
    return 0
}

# Main entrypoint function
main() {
    log "INFO" "=== Docker Container Starting ==="

    # Initialize backup system
    if ! initialize_backup_system; then
        log "ERROR" "Backup system initialization failed"
        exit 1
    fi

    # Start PostgreSQL
    if ! start_postgresql; then
        log "ERROR" "PostgreSQL startup failed"
        exit 1
    fi

    # Setup backup system
    if ! setup_backup_system; then
        log "ERROR" "Backup system setup failed"
        exit 1
    fi

    log "INFO" "=== All services started successfully ==="
    log "INFO" "Container is ready. Monitoring logs..."

    # Keep the container running by tailing the log file
    tail -f /backup/logs/backup.log
}

# Handle script termination
cleanup() {
    log "INFO" "Container shutting down..."
    # Kill any background processes
    pkill -f "postgres" || true
    pkill -f "crond" || true
}

trap cleanup EXIT

# Run main function
main "$@"
