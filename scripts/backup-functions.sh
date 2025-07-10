#!/bin/bash

# Source environment variables if available
if [[ -f /etc/environment ]]; then
    # Safely source environment variables
    set -a  # automatically export all variables
    source /etc/environment 2>/dev/null || true
    set +a  # disable automatic export
fi

# Global variable for the rclone remote name
REMOTE_NAME=""
RCLONE_CONFIG_PATH="~/.config/rclone/rclone.conf"

# Logging function
log() {
    local level="$1"
    local message="$2"
    local log_string="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
    echo "$log_string" >> /backup/logs/backup.log
    echo "$log_string" >&2
}

# Get the first remote name from the rclone config
get_first_remote_name() {
    local config_file="$1"
    grep -m 1 "^\[.*\]" "$config_file" | sed 's/^\[\(.*\)\]/\1/'
}

# Debug function to show environment variables
debug_env() {
    log "DEBUG" "Environment variable status:"
    local required_vars=(
        "POSTGRES_USER"
        "POSTGRES_PASSWORD"
        "POSTGRES_DB"
        "RCLONE_CONF_BASE64"
        "RCLONE_REMOTE_PATH"
        "RCLONE_REMOTE_NAME"
        "BASE_BACKUP_SCHEDULE"
        "BACKUP_RETENTION_DAYS"
    )
    
    for var in "${required_vars[@]}"; do
        if [[ -n "${!var}" ]]; then
            if [[ "$var" == "POSTGRES_PASSWORD" || "$var" == "RCLONE_CONF_BASE64" ]]; then
                log "DEBUG" "  $var: [SET - hidden for security]"
            else
                log "DEBUG" "  $var: ${!var}"
            fi
        else
            log "DEBUG" "  $var: [NOT SET]"
        fi
    done
}

# Check for required environment variables
check_env() {
    local required_vars=(
        "POSTGRES_USER"
        "POSTGRES_PASSWORD"
        "RCLONE_CONF_BASE64"
    )
    
    log "INFO" "Checking required environment variables..."
    
    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            missing_vars+=("$var")
            log "ERROR" "Required environment variable not set: $var"
        else
            if [[ "$var" == "POSTGRES_PASSWORD" || "$var" == "RCLONE_CONF_BASE64" ]]; then
                log "INFO" "Required environment variable is set: $var [value hidden]"
            else
                log "INFO" "Required environment variable is set: $var = ${!var}"
            fi
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log "ERROR" "Required environment variables are not set: ${missing_vars[*]}"
        log "INFO" "Attempting to source /etc/environment..."
        if [[ -f /etc/environment ]]; then
            source /etc/environment
            log "INFO" "Re-checking environment variables after sourcing /etc/environment..."
            
            # Re-check missing variables
            local still_missing=()
            for var in "${missing_vars[@]}"; do
                if [[ -z "${!var}" ]]; then
                    still_missing+=("$var")
                    log "ERROR" "Environment variable still missing after sourcing /etc/environment: $var"
                else
                    log "INFO" "Environment variable found after sourcing /etc/environment: $var"
                fi
            done
            
            if [[ ${#still_missing[@]} -gt 0 ]]; then
                log "ERROR" "Environment variables still missing after sourcing /etc/environment: ${still_missing[*]}"
                debug_env
                return 1
            else
                log "INFO" "All required environment variables are now available."
            fi
        else
            log "ERROR" "/etc/environment file not found."
            log "ERROR" "Cannot recover from missing environment variables: ${missing_vars[*]}"
            debug_env
            return 1
        fi
    else
        log "INFO" "All required environment variables are set."
    fi

    # Additional checks for optional but important variables
    if [[ -z "$PGDATA" ]]; then
        log "WARN" "PGDATA environment variable not set. Using default PostgreSQL data directory."
    else
        log "INFO" "PGDATA environment variable set: $PGDATA"
        # Check if PGDATA directory exists and is accessible
        if [[ ! -d "$PGDATA" ]]; then
            log "ERROR" "PGDATA directory does not exist: $PGDATA"
            return 1
        fi
        if [[ ! -r "$PGDATA" || ! -x "$PGDATA" ]]; then
            log "ERROR" "PGDATA directory is not accessible: $PGDATA"
            return 1
        fi
        log "INFO" "PGDATA directory verified: $PGDATA"
    fi
    
    return 0
}

# Setup rclone
setup_rclone() {
    log "INFO" "Setting up rclone..."

    mkdir -p "$(dirname "$RCLONE_CONFIG_PATH")"

    if ! echo "$RCLONE_CONF_BASE64" | base64 -d | tr -d '\r' > "$RCLONE_CONFIG_PATH"; then
        log "ERROR" "Failed to decode RCLONE_CONF_BASE64 or write to $RCLONE_CONFIG_PATH."
        return 1
    fi
    
    chmod 644 "$RCLONE_CONFIG_PATH"
    log "INFO" "Rclone configuration created at $RCLONE_CONFIG_PATH."
    
    # Use RCLONE_REMOTE_NAME if specified, otherwise extract first remote from config
    if [[ -n "$RCLONE_REMOTE_NAME" ]]; then
        REMOTE_NAME="$RCLONE_REMOTE_NAME"
        log "INFO" "Using user-specified rclone remote: '$REMOTE_NAME'"
    else
        REMOTE_NAME=$(get_first_remote_name "$RCLONE_CONFIG_PATH")
        if [[ -n "$REMOTE_NAME" ]]; then
            log "INFO" "Using first rclone remote from config: '$REMOTE_NAME'"
        else
            log "ERROR" "No remote found in rclone configuration and RCLONE_REMOTE_NAME not specified."
            return 1
        fi
    fi
    
    if [[ -z "$REMOTE_NAME" ]] || ! [[ "$REMOTE_NAME" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        log "ERROR" "Invalid remote name: '$REMOTE_NAME'."
        return 1
    fi
    
    if [[ "${RCLONE_SKIP_VERIFY}" == "true" ]]; then
        log "WARN" "Skipping rclone configuration verification."
        return 0
    fi
    
    log "INFO" "Verifying rclone configuration for remote '${REMOTE_NAME}'..."
    if ! rclone lsd "${REMOTE_NAME}:" --config "$RCLONE_CONFIG_PATH" --timeout="10s" --contimeout="8s" --retries=1 > /dev/null; then
        log "ERROR" "Rclone configuration test failed for remote '${REMOTE_NAME}'."
        return 1
    fi
    
    log "INFO" "Rclone configuration verified successfully."
}

# Compress and upload a file
compress_and_upload() {
    local source_file="$1"
    local remote_path="$2"
    local remote_filename="$3"
    local temp_compressed_file

    if [[ ! -s "$source_file" ]]; then
        log "WARN" "Source file $source_file does not exist or is empty. Skipping upload."
        return 0
    fi

    log "INFO" "Compressing $source_file..."
    temp_compressed_file=$(mktemp)
    
    # Ensure cleanup on exit
    trap "rm -f '$temp_compressed_file'" EXIT
    
    if ! gzip -c "$source_file" > "$temp_compressed_file"; then
        log "ERROR" "Failed to compress $source_file."
        rm -f "$temp_compressed_file"
        return 1
    fi

    log "INFO" "Verifying compressed file..."
    if ! gzip -t "$temp_compressed_file"; then
        log "ERROR" "Compressed file is corrupted. Aborting upload."
        rm -f "$temp_compressed_file"
        return 1
    fi
    log "INFO" "Compressed file verified successfully."

    log "INFO" "Uploading $source_file to ${remote_path}/${remote_filename}"
    
    if ! rclone rcat "${REMOTE_NAME}:${remote_path}/${remote_filename}" --config "$RCLONE_CONFIG_PATH" < "$temp_compressed_file"; then
        log "ERROR" "Failed to upload $source_file."
        rm -f "$temp_compressed_file"
        return 1
    fi
    
    rm -f "$temp_compressed_file"
    log "INFO" "Successfully uploaded $remote_filename."
    
    # Clear the trap since we've cleaned up manually
    trap - EXIT
}

# Cleanup old backups
cleanup_old_backups() {
    local backup_type="$1"
    local retention_days="${BACKUP_RETENTION_DAYS:-3}"
    local cutoff_date=$(date -d "$retention_days days ago" +%Y%m%d)
    
    local db_identifier=$(get_database_identifier)
    local remote_base_path="${RCLONE_REMOTE_PATH:-postgres-backups}/${db_identifier}"
    
    log "INFO" "Cleaning up $backup_type backups older than $retention_days days in ${remote_base_path}/${backup_type}/"
    
    # Check if the remote directory exists
    if ! rclone lsd "${REMOTE_NAME}:${remote_base_path}/${backup_type}/" --config "$RCLONE_CONFIG_PATH" > /dev/null 2>&1; then
        log "WARN" "Remote directory ${remote_base_path}/${backup_type}/ does not exist. Skipping cleanup."
        return 0
    fi
    
    # Only handle base backups now (WAL archiving removed)
    if [[ "$backup_type" == "base" ]]; then
        rclone lsf "${REMOTE_NAME}:${remote_base_path}/${backup_type}/" --config "$RCLONE_CONFIG_PATH" | while read -r file; do
            if [[ -z "$file" ]]; then
                continue
            fi
            
            # Support both old format (YYYYMMDD.tar.gz) and new format (YYYYMMDD_HHMMSS.tar.gz)
            if [[ "$file" =~ ([0-9]{8})(_[0-9]{6})?\.tar\.gz$ ]]; then
                file_date="${BASH_REMATCH[1]}"
                if [[ "$file_date" < "$cutoff_date" ]]; then
                    log "INFO" "Deleting old base backup: $file"
                    rclone delete "${REMOTE_NAME}:${remote_base_path}/${backup_type}/${file}" --config "$RCLONE_CONFIG_PATH"
                fi
            fi
        done
    else
        log "WARN" "Backup type '$backup_type' is not supported. Only 'base' backups are supported."
    fi
    
    log "INFO" "Cleanup for ${backup_type} backups completed."
}

# Configure pgbackrest stanza
configure_pgbackrest_stanza() {
    local stanza_name="${PGBACKREST_STANZA:-main}"
    local pgdata="${PGDATA:-/var/lib/postgresql/data}"
    local socket_dir="${PGHOST:-/var/run/postgresql}"
    local pg_port="${PGPORT:-5432}"
    local pg_user="${POSTGRES_USER:-postgres}"

    log "INFO" "Configuring pgbackrest stanza: $stanza_name"

    # Create stanza configuration
    cat >> /etc/pgbackrest/pgbackrest.conf << EOF

[${stanza_name}]
pg1-path=${pgdata}
pg1-socket-path=${socket_dir}
pg1-port=${pg_port}
pg1-user=${pg_user}
pg1-database=postgres
EOF

    log "INFO" "Stanza configuration added to pgbackrest.conf"

    # Create the stanza
    log "INFO" "Creating pgbackrest stanza..."
    if ! su - postgres -c "pgbackrest --stanza=${stanza_name} stanza-create"; then
        log "ERROR" "Failed to create pgbackrest stanza"
        return 1
    fi

    log "INFO" "Pgbackrest stanza created successfully"
    return 0
}

# Perform full backup using pgbackrest
perform_pgbackrest_backup() {
    local stanza_name="${PGBACKREST_STANZA:-main}"
    local backup_type="${1:-full}"

    log "INFO" "Starting pgbackrest $backup_type backup for stanza: $stanza_name"

    # Perform the backup
    local backup_output
    if ! backup_output=$(su - postgres -c "pgbackrest --stanza=${stanza_name} --type=${backup_type} backup" 2>&1); then
        log "ERROR" "Pgbackrest backup failed: $backup_output"
        return 1
    fi

    log "INFO" "Pgbackrest backup completed successfully"
    log "DEBUG" "Backup output: $backup_output"

    # Get the latest backup info
    local backup_info
    if ! backup_info=$(su - postgres -c "pgbackrest --stanza=${stanza_name} info --output=json" 2>/dev/null); then
        log "WARN" "Could not retrieve backup info"
        return 0
    fi

    log "INFO" "Latest backup info retrieved"
    return 0
}

# Create compressed backup archive
create_backup_archive() {
    local stanza_name="${PGBACKREST_STANZA:-main}"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_dir="/var/lib/pgbackrest/backup/${stanza_name}"
    local archive_name="pgbackrest_${stanza_name}_${timestamp}.tar.gz"
    local archive_path="/tmp/${archive_name}"

    log "INFO" "Creating backup archive: $archive_name"

    # Check if backup directory exists
    if [[ ! -d "$backup_dir" ]]; then
        log "ERROR" "Backup directory does not exist: $backup_dir"
        return 1
    fi

    # Create compressed archive
    if ! tar -czf "$archive_path" -C "/var/lib/pgbackrest/backup" "${stanza_name}"; then
        log "ERROR" "Failed to create backup archive"
        return 1
    fi

    # Verify archive
    if ! tar -tzf "$archive_path" > /dev/null; then
        log "ERROR" "Backup archive verification failed"
        rm -f "$archive_path"
        return 1
    fi

    log "INFO" "Backup archive created and verified: $archive_path"
    echo "$archive_path"
    return 0
}

# Check for and perform daily backup if needed
check_and_perform_daily_backup() {
    log "INFO" "Checking for today's full base backup..."

    local today=$(date '+%Y%m%d')
    local db_identifier=$(get_database_identifier)
    local remote_base_path="${RCLONE_REMOTE_PATH:-postgres-backups}/${db_identifier}/base"

    # Check for backups with today's date (both old and new format)
    if rclone lsf "${REMOTE_NAME}:${remote_base_path}/" --config "$RCLONE_CONFIG_PATH" | grep -q "${today}"; then
        log "INFO" "Today's backup already exists. Skipping."
    else
        log "INFO" "Today's backup not found. Starting base backup."
        perform_full_backup
    fi
}

# Perform complete backup process
perform_full_backup() {
    log "INFO" "Starting complete backup process..."

    # Configure pgbackrest stanza if not already done
    local stanza_name="${PGBACKREST_STANZA:-main}"
    if ! su - postgres -c "pgbackrest --stanza=${stanza_name} info" > /dev/null 2>&1; then
        log "INFO" "Stanza not found, configuring pgbackrest..."
        if ! configure_pgbackrest_stanza; then
            log "ERROR" "Failed to configure pgbackrest stanza"
            return 1
        fi
    fi

    # Perform pgbackrest backup
    if ! perform_pgbackrest_backup "full"; then
        log "ERROR" "Pgbackrest backup failed"
        return 1
    fi

    # Create compressed archive
    local archive_path
    if ! archive_path=$(create_backup_archive); then
        log "ERROR" "Failed to create backup archive"
        return 1
    fi

    # Upload to remote storage
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local db_identifier=$(get_database_identifier)
    local remote_path="${RCLONE_REMOTE_PATH:-postgres-backups}/${db_identifier}/base"
    local remote_filename="pgbackrest_${stanza_name}_${timestamp}.tar.gz"

    if ! compress_and_upload "$archive_path" "$remote_path" "$remote_filename"; then
        log "ERROR" "Failed to upload backup archive"
        rm -f "$archive_path"
        return 1
    fi

    # Clean up local archive
    rm -f "$archive_path"

    # Clean up old backups
    cleanup_old_backups "base"

    log "INFO" "Complete backup process finished successfully"
    return 0
}

# Get database identifier for backup operations
get_database_identifier() {
    if [[ -n "$POSTGRES_DB" ]]; then
        # User specified a specific database for backup
        echo "$POSTGRES_DB"
    else
        # No specific database specified, use stanza name as identifier
        echo "${PGBACKREST_STANZA:-main}"
    fi
}

# Wait for PostgreSQL to be ready
wait_for_postgres() {
    local max_wait="${1:-60}"
    local interval=5
    local waited=0
    
    log "INFO" "Waiting for PostgreSQL to become available..."
    
    while ! PGPASSWORD="$POSTGRES_PASSWORD" pg_isready -h 127.0.0.1 -U "$POSTGRES_USER" -d postgres -q; do
        if [ $waited -ge $max_wait ]; then
            log "ERROR" "Timeout waiting for PostgreSQL."
            return 1
        fi
        log "INFO" "PostgreSQL not ready yet, waiting $interval seconds... ($waited/$max_wait)"
        sleep $interval
        waited=$((waited + interval))
    done
    
    # Double-check with actual query to make sure user/password is working
    if ! PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d postgres -c "SELECT 1;" > /dev/null 2>&1; then
        log "ERROR" "PostgreSQL is running but authentication failed. Check POSTGRES_USER and POSTGRES_PASSWORD."
        return 1
    fi
    
    log "INFO" "PostgreSQL is ready and authentication confirmed."
    return 0
}

# Perform incremental backup
perform_incremental_backup() {
    log "INFO" "Starting incremental backup process..."

    # Configure pgbackrest stanza if not already done
    local stanza_name="${PGBACKREST_STANZA:-main}"
    if ! su - postgres -c "pgbackrest --stanza=${stanza_name} info" > /dev/null 2>&1; then
        log "INFO" "Stanza not found, creating stanza..."
        if ! create_pgbackrest_stanza; then
            log "ERROR" "Failed to create pgbackrest stanza"
            return 1
        fi
    fi

    # Perform pgbackrest incremental backup
    if ! perform_pgbackrest_backup "incr"; then
        log "ERROR" "Pgbackrest incremental backup failed"
        return 1
    fi

    log "INFO" "Incremental backup completed successfully"
    return 0
}

# Perform differential backup
perform_differential_backup() {
    log "INFO" "Starting differential backup process..."

    # Configure pgbackrest stanza if not already done
    local stanza_name="${PGBACKREST_STANZA:-main}"
    if ! su - postgres -c "pgbackrest --stanza=${stanza_name} info" > /dev/null 2>&1; then
        log "INFO" "Stanza not found, creating stanza..."
        if ! create_pgbackrest_stanza; then
            log "ERROR" "Failed to create pgbackrest stanza"
            return 1
        fi
    fi

    # Perform pgbackrest differential backup
    if ! perform_pgbackrest_backup "diff"; then
        log "ERROR" "Pgbackrest differential backup failed"
        return 1
    fi

    log "INFO" "Differential backup completed successfully"
    return 0
}