#!/bin/bash
# pgBackRest configuration and management module

# Configure pgbackrest stanza
configure_pgbackrest_stanza() {
    local stanza_name="${PGBACKREST_STANZA:-main}"
    local pgdata="${PGDATA:-/var/lib/postgresql/data}"
    local socket_dir="${PGHOST:-/var/run/postgresql}"
    local pg_port="${PGPORT:-5432}"
    local pg_user="${POSTGRES_USER:-postgres}"
    local pg_database="${POSTGRES_DB:-postgres}"

    log "INFO" "Configuring pgbackrest stanza: $stanza_name"
    log "INFO" "Using pgdata: $pgdata"
    log "INFO" "Using socket dir: $socket_dir"
    log "INFO" "Using port: $pg_port"
    log "INFO" "Using user: $pg_user"
    log "INFO" "Using database: $pg_database"

    # Ensure PostgreSQL is running before configuring stanza
    if ! wait_for_postgres 60; then
        log "ERROR" "PostgreSQL is not ready for stanza configuration"
        return 1
    fi

    # Verify that archive_mode is enabled
    log "INFO" "Verifying PostgreSQL archive mode configuration..."
    local archive_mode_check
    
    # Try connecting as postgres user via socket first (most reliable)
    archive_mode_check=$(su-exec postgres psql -d "$pg_database" -t -c "SHOW archive_mode;" 2>/dev/null | tr -d ' ')
    
    # If that fails, try with the configured user
    if [ -z "$archive_mode_check" ] || [ "$archive_mode_check" = "" ]; then
        archive_mode_check=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$pg_user" -d "$pg_database" -t -c "SHOW archive_mode;" 2>/dev/null | tr -d ' ')
    fi

    if [ "$archive_mode_check" != "on" ]; then
        log "ERROR" "Archive mode is not enabled (current: $archive_mode_check). This is required for pgBackRest."
        log "ERROR" "Please ensure archive_mode=on is set in postgresql.conf and PostgreSQL has been restarted."
        return 1
    fi

    log "INFO" "Archive mode is enabled: $archive_mode_check"

    # Create stanza configuration
    cat >> /etc/pgbackrest/pgbackrest.conf << EOF

[${stanza_name}]
pg1-path=${pgdata}
pg1-socket-path=${socket_dir}
pg1-port=${pg_port}
pg1-user=postgres
pg1-database=${pg_database}
EOF

    log "INFO" "Stanza configuration added to pgbackrest.conf"

    # Fix permissions on config file
    chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
    chmod 640 /etc/pgbackrest/pgbackrest.conf

    # Show the configuration for debugging
    log "DEBUG" "Current pgbackrest configuration:"
    cat /etc/pgbackrest/pgbackrest.conf

    # Create the stanza using su-exec instead of su
    log "INFO" "Creating pgbackrest stanza..."
    if ! su-exec postgres bash -c "export PGBACKREST_STANZA=\"${stanza_name}\" && pgbackrest stanza-create"; then
        log "ERROR" "Failed to create pgbackrest stanza"
        log "ERROR" "Checking pgbackrest configuration..."
        su-exec postgres bash -c "export PGBACKREST_STANZA=\"${stanza_name}\" && pgbackrest check" || true
        # Try with command line parameter as fallback
        log "INFO" "Trying with command line parameter as fallback..."
        su-exec postgres bash -c "export PGBACKREST_STANZA=\"${stanza_name}\" && pgbackrest --stanza=\"${stanza_name}\" stanza-create" || true
        return 1
    fi

    log "INFO" "Pgbackrest stanza created successfully"
    
    # Ensure proper permissions for pgBackRest directories
    log "INFO" "Setting proper permissions for pgBackRest directories..."
    chown -R postgres:postgres /var/lib/pgbackrest /var/log/pgbackrest /etc/pgbackrest
    chmod -R 750 /var/lib/pgbackrest /var/log/pgbackrest
    chmod 640 /etc/pgbackrest/pgbackrest.conf
    
    # Now update the archive_command to use pgbackrest
    log "INFO" "Updating archive_command in postgresql.conf..."
    local pgdata="${PGDATA:-/var/lib/postgresql/data}"
    
    # Update the archive_command to use pgbackrest with proper environment
    sed -i "s|archive_command = '/bin/true'|archive_command = 'PGBACKREST_STANZA=${stanza_name} pgbackrest --stanza=${stanza_name} archive-push %p'|g" "$pgdata/postgresql.conf"
    
    # Reload PostgreSQL configuration
    log "INFO" "Reloading PostgreSQL configuration..."
    if ! su-exec postgres pg_ctl reload -D "$pgdata"; then
        log "ERROR" "Failed to reload PostgreSQL configuration"
        return 1
    fi

    # Wait for configuration to take effect
    log "INFO" "Waiting for configuration reload to take effect..."
    sleep 10

    # Verify the archive_command was updated
    log "INFO" "Verifying archive_command configuration..."
    local max_retries=5
    local retry_count=0
    local archive_cmd_check=""

    while [ $retry_count -lt $max_retries ]; do
        archive_cmd_check=$(su-exec postgres psql -d "$pg_database" -t -c "SHOW archive_command;" 2>/dev/null | sed 's/^[ \t]*//;s/[ \t]*$//')
        if [[ "$archive_cmd_check" == *"pgbackrest"* ]]; then
            log "INFO" "Archive command updated successfully: $archive_cmd_check"
            break
        else
            log "WARN" "Archive command not yet updated (attempt $((retry_count + 1))/$max_retries): $archive_cmd_check"
            sleep 5
            retry_count=$((retry_count + 1))
        fi
    done

    if [[ "$archive_cmd_check" != *"pgbackrest"* ]]; then
        log "ERROR" "Archive command was not updated after $max_retries attempts"
        log "ERROR" "Current archive_command: $archive_cmd_check"
        return 1
    fi
    
    # Force a WAL switch to trigger archiving
    log "INFO" "Forcing WAL switch to trigger archiving..."
    if ! su-exec postgres psql -d "$pg_database" -c "SELECT pg_switch_wal();" 2>/dev/null; then
        log "WARN" "Failed to force WAL switch, but continuing..."
    fi
    log "INFO" "Forcing WAL switch to trigger archiving..."
    if ! su-exec postgres psql -d "$pg_database" -c "SELECT pg_switch_wal();"; then
        log "WARN" "Failed to force WAL switch, but continuing..."
    fi

    # Wait longer for archiving to complete
    log "INFO" "Waiting for WAL archiving to complete..."
    sleep 15
    
    # Check if any WAL files have been archived
    log "INFO" "Checking for archived WAL files..."
    local archive_dir="/var/lib/pgbackrest/archive/${stanza_name}"
    local max_wait=60
    local wait_time=0
    local archived_count=0

    while [ $wait_time -lt $max_wait ]; do
        if [ -d "$archive_dir" ]; then
            archived_count=$(find "$archive_dir" -type f \( -name "*.gz" -o -name "*.lz4" -o -name "*.xz" -o -name "*.bz2" -o -name "*-*" \) | wc -l)
            if [ "$archived_count" -gt 0 ]; then
                log "INFO" "Found ${archived_count} archived WAL files"
                log "INFO" "WAL archiving is working correctly"
                break
            fi
        fi

        if [ $wait_time -eq 0 ]; then
            log "INFO" "Waiting for WAL files to be archived..."
        fi

        sleep 5
        wait_time=$((wait_time + 5))

        if [ $((wait_time % 15)) -eq 0 ]; then
            log "INFO" "Still waiting for WAL archiving... (${wait_time}s/${max_wait}s)"
            # Force another WAL switch to trigger archiving
            if ! su-exec postgres psql -d "$pg_database" -c "SELECT pg_switch_wal();" 2>/dev/null; then
                log "WARN" "Failed to force WAL switch"
            fi
        fi
    done

    if [ "$archived_count" -eq 0 ]; then
        log "ERROR" "No archived WAL files found after ${max_wait} seconds"
        log "ERROR" "WAL archiving is not working properly. This will cause backup failures."

        # Show PostgreSQL log for debugging
        log "INFO" "Recent PostgreSQL log entries:"
        tail -20 "$pgdata/log/"*.log 2>/dev/null || log "WARN" "Could not read PostgreSQL logs"
        
        # Show current archive_command
        local current_archive_cmd=$(su-exec postgres psql -d "$pg_database" -t -c "SHOW archive_command;" 2>/dev/null | sed 's/^[ \t]*//;s/[ \t]*$//')
        log "ERROR" "Current archive_command: $current_archive_cmd"
        
        # Try to manually test archive command
        log "INFO" "Testing archive command manually..."
        local wal_dir="${PGDATA:-/var/lib/postgresql/data}/pg_wal"
        if [ -d "$wal_dir" ]; then
            # Find a WAL file to test with
            local test_wal_file=$(find "$wal_dir" -name "[0-9A-F]*" -type f | head -1)
            if [ -n "$test_wal_file" ]; then
                log "INFO" "Testing with WAL file: $(basename "$test_wal_file")"
                if su-exec postgres bash -c "export PGBACKREST_STANZA=\"${stanza_name}\" && pgbackrest --stanza=\"${stanza_name}\" archive-push \"$test_wal_file\""; then
                    log "INFO" "Manual archive test succeeded"
                else
                    log "ERROR" "Manual archive test failed"
                fi
            else
                log "WARN" "No WAL files found for testing"
            fi
        fi
        
        return 1
    fi
    
    return 0
}

# Verify WAL archiving is working before backup
verify_wal_archiving() {
    local stanza_name="${PGBACKREST_STANZA:-main}"
    local pg_database="${POSTGRES_DB:-postgres}"
    
    log "INFO" "Verifying WAL archiving is working..."
    
    # Force a WAL switch and check if it gets archived
    local pre_switch_lsn=$(su-exec postgres psql -d "$pg_database" -t -c "SELECT pg_current_wal_lsn();" 2>/dev/null | tr -d ' ')
    
    if [ -z "$pre_switch_lsn" ]; then
        log "ERROR" "Failed to get current WAL LSN"
        return 1
    fi
    
    log "INFO" "Current WAL LSN before switch: $pre_switch_lsn"
    
    # Force WAL switch
    if ! su-exec postgres psql -d "$pg_database" -c "SELECT pg_switch_wal();" 2>/dev/null; then
        log "ERROR" "Failed to force WAL switch"
        return 1
    fi
    
    log "INFO" "WAL switch forced, waiting for archiving..."
    
    # Wait up to 60 seconds for the WAL file to be archived
    local max_wait=60
    local wait_time=0
    local archive_dir="/var/lib/pgbackrest/archive/${stanza_name}"
    
    while [ $wait_time -lt $max_wait ]; do
        if [ -d "$archive_dir" ]; then
            # Look for any archived WAL files (recent ones)
            local archived_count=$(find "$archive_dir" -type f \( -name "*.gz" -o -name "*.lz4" -o -name "*.xz" -o -name "*.bz2" -o -name "*-*" \) -mmin -2 2>/dev/null | wc -l)
            if [ "$archived_count" -gt 0 ]; then
                log "INFO" "WAL archiving verified - found newly archived WAL files"
                return 0
            fi
        fi
        
        sleep 2
        wait_time=$((wait_time + 2))
        
        if [ $((wait_time % 10)) -eq 0 ]; then
            log "INFO" "Still waiting for WAL archiving... (${wait_time}s/${max_wait}s)"
        fi
    done
    
    log "ERROR" "WAL archiving verification failed - no WAL files archived within ${max_wait} seconds"
    return 1
}

# Perform full backup using pgbackrest
perform_pgbackrest_backup() {
    local stanza_name="${PGBACKREST_STANZA:-main}"
    local backup_type="${1:-full}"

    log "INFO" "Starting pgbackrest $backup_type backup for stanza: $stanza_name"

    # Ensure PostgreSQL is ready
    if ! wait_for_postgres 30; then
        log "ERROR" "PostgreSQL is not ready for backup"
        return 1
    fi

    # For full backups, ensure WAL archiving is working
    if [ "$backup_type" = "full" ]; then
        log "INFO" "Verifying WAL archiving before starting full backup..."
        
        if ! verify_wal_archiving; then
            log "ERROR" "WAL archiving verification failed - backup will likely fail"
            return 1
        fi
        
        log "INFO" "WAL archiving verified successfully"
    fi

    # Perform the backup using su-exec
    local backup_output
    if ! backup_output=$(su-exec postgres bash -c "export PGBACKREST_STANZA=\"${stanza_name}\" && pgbackrest --type=\"${backup_type}\" backup" 2>&1); then
        log "ERROR" "Pgbackrest backup failed: $backup_output"
        log "ERROR" "Checking stanza status..."
        su-exec postgres bash -c "export PGBACKREST_STANZA=\"${stanza_name}\" && pgbackrest info" || true
        return 1
    fi

    log "INFO" "Pgbackrest backup completed successfully"
    log "DEBUG" "Backup output: $backup_output"

    # Get the latest backup info
    local backup_info
    if ! backup_info=$(su-exec postgres bash -c "export PGBACKREST_STANZA=\"${stanza_name}\" && pgbackrest info --output=json" 2>/dev/null); then
        log "WARN" "Could not retrieve backup info"
        return 0
    fi

    log "INFO" "Latest backup info retrieved"
    return 0
}

# Check if full backup exists
check_full_backup_exists() {
    local stanza_name="${PGBACKREST_STANZA:-main}"

    log "INFO" "Checking for existing full backup..."

    # Check if stanza exists and has backups
    if su-exec postgres bash -c "export PGBACKREST_STANZA=\"$stanza_name\" && pgbackrest info" >/dev/null 2>&1; then
        # Get backup info and check for full backups
        local backup_info=$(su-exec postgres bash -c "export PGBACKREST_STANZA=\"$stanza_name\" && pgbackrest info --output=json" 2>/dev/null)

        if [ -n "$backup_info" ]; then
            # Check if there are any full backups
            local full_backup_count=$(echo "$backup_info" | jq -r '.[] | .backup[] | select(.type=="full") | .label' 2>/dev/null | wc -l)

            if [ "$full_backup_count" -gt 0 ]; then
                log "INFO" "Found $full_backup_count full backup(s)"
                return 0
            else
                log "INFO" "No full backups found"
                return 1
            fi
        else
            log "INFO" "No backup information available"
            return 1
        fi
    else
        log "INFO" "Stanza does not exist or has no backups"
        return 1
    fi
}