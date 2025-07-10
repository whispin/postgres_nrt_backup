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

    # Set default PGDATA if not set
    export PGDATA="${PGDATA:-/var/lib/postgresql/data}"

    # Initialize PostgreSQL data directory if needed
    if [ ! -s "$PGDATA/PG_VERSION" ]; then
        log "INFO" "Initializing PostgreSQL database..."
        # Create data directory with proper permissions
        mkdir -p "$PGDATA"
        chown postgres:postgres "$PGDATA"
        chmod 700 "$PGDATA"

        # Initialize database as postgres user
        su-exec postgres initdb --auth-local=trust --auth-host=md5

        # Set up basic postgresql.conf settings
        echo "listen_addresses = '*'" >> "$PGDATA/postgresql.conf"
        echo "port = 5432" >> "$PGDATA/postgresql.conf"
        echo "logging_collector = on" >> "$PGDATA/postgresql.conf"
        echo "log_directory = 'log'" >> "$PGDATA/postgresql.conf"
        echo "log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'" >> "$PGDATA/postgresql.conf"

        # Set up pg_hba.conf for authentication
        {
            echo "local all all trust"
            echo "host all all 127.0.0.1/32 md5"
            echo "host all all ::1/128 md5"
            echo "host all all 0.0.0.0/0 md5"
        } > "$PGDATA/pg_hba.conf"

        # Create user and database if specified
        if [ -n "$POSTGRES_USER" ] && [ "$POSTGRES_USER" != "postgres" ]; then
            log "INFO" "Creating user: $POSTGRES_USER"
            su-exec postgres postgres --single -jE <<-EOSQL
                CREATE USER "$POSTGRES_USER" WITH SUPERUSER PASSWORD '$POSTGRES_PASSWORD';
EOSQL
        fi

        if [ -n "$POSTGRES_DB" ] && [ "$POSTGRES_DB" != "postgres" ]; then
            log "INFO" "Creating database: $POSTGRES_DB"
            su-exec postgres postgres --single -jE <<-EOSQL
                CREATE DATABASE "$POSTGRES_DB" OWNER "$POSTGRES_USER";
EOSQL
        fi
    fi

    # Start PostgreSQL in background
    log "INFO" "Starting PostgreSQL server..."
    su-exec postgres postgres &
    POSTGRES_PID=$!

    # Wait for PostgreSQL to be ready
    log "INFO" "Waiting for PostgreSQL to start..."
    if ! wait_for_postgres 120; then
        log "ERROR" "PostgreSQL failed to start"
        # Kill the postgres process if it's still running
        kill $POSTGRES_PID 2>/dev/null || true
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
    # Gracefully stop PostgreSQL if it's running
    if [ -n "$POSTGRES_PID" ] && kill -0 "$POSTGRES_PID" 2>/dev/null; then
        log "INFO" "Stopping PostgreSQL gracefully..."
        kill -TERM "$POSTGRES_PID"
        # Wait up to 30 seconds for graceful shutdown
        for i in $(seq 1 30); do
            if ! kill -0 "$POSTGRES_PID" 2>/dev/null; then
                break
            fi
            sleep 1
        done
        # Force kill if still running
        if kill -0 "$POSTGRES_PID" 2>/dev/null; then
            log "WARN" "Force killing PostgreSQL..."
            kill -KILL "$POSTGRES_PID" 2>/dev/null || true
        fi
    fi
    # Kill any remaining background processes
    pkill -f "crond" || true
}

trap cleanup EXIT

# Run main function
main "$@"
