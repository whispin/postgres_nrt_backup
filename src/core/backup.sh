#!/bin/bash
# Backup operations module

# Create compressed repository archive
create_compressed_repository_archive() {
    local backup_type="$1"
    local stanza_name="${PGBACKREST_STANZA:-main}"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local repo_path="/var/lib/pgbackrest"
    local archive_name="pgbackrest_repo_${stanza_name}_${backup_type}_${timestamp}.tar.gz"
    local archive_path="/tmp/${archive_name}"

    log "INFO" "Creating compressed repository archive: $archive_name"

    # Check if repository directory exists and has content
    if [[ ! -d "$repo_path" ]]; then
        log "ERROR" "pgBackRest repository directory does not exist: $repo_path"
        return 1
    fi

    # Check if repository has content
    if [[ ! "$(ls -A "$repo_path" 2>/dev/null)" ]]; then
        log "WARN" "pgBackRest repository directory is empty: $repo_path"
        # Create a minimal archive to avoid issues
        mkdir -p "${repo_path}/empty"
        echo "Repository was empty during backup" > "${repo_path}/empty/README.txt"
    fi

    # Create compressed archive with better compression and error handling
    log "INFO" "Creating tar.gz archive from $repo_path"
    if ! tar --create \
             --gzip \
             --file="$archive_path" \
             --directory="$(dirname "$repo_path")" \
             --verbose \
             --exclude="*.lock" \
             --exclude="*.tmp" \
             "$(basename "$repo_path")"; then
        log "ERROR" "Failed to create compressed repository archive"
        rm -f "$archive_path"
        return 1
    fi

    # Verify archive integrity with multiple checks
    log "INFO" "Verifying archive integrity..."
    
    # Check if file exists and has size
    if [[ ! -s "$archive_path" ]]; then
        log "ERROR" "Archive file is empty or does not exist"
        rm -f "$archive_path"
        return 1
    fi
    
    # Test gzip integrity
    if ! gzip -t "$archive_path" 2>/dev/null; then
        log "ERROR" "Archive gzip integrity check failed"
        rm -f "$archive_path"
        return 1
    fi
    
    # Test tar listing
    if ! tar -tzf "$archive_path" >/dev/null 2>&1; then
        log "ERROR" "Archive tar listing check failed"
        rm -f "$archive_path"
        return 1
    fi

    # Get file size for logging
    local file_size=$(du -h "$archive_path" | cut -f1)
    log "INFO" "Compressed repository archive created successfully: $archive_path (size: $file_size)"
    echo "$archive_path"
    return 0
}

# Upload pgBackRest repository to remote storage (compressed)
upload_pgbackrest_repository() {
    local backup_type="$1"
    
    # Ensure REMOTE_NAME is set
    if ! ensure_remote_name; then
        log "ERROR" "Failed to determine rclone remote name. Cannot upload repository."
        return 1
    fi
    
    local db_identifier=$(get_database_identifier)
    local repo_remote_path="${RCLONE_REMOTE_PATH:-postgres-backups}/${db_identifier}/repository"

    log "INFO" "Uploading compressed pgBackRest repository for $backup_type backup..."

    # Create compressed repository archive
    local archive_path
    if ! archive_path=$(create_compressed_repository_archive "$backup_type"); then
        log "ERROR" "Failed to create compressed repository archive"
        return 1
    fi

    # Create remote repository directory
    if ! rclone mkdir "${REMOTE_NAME}:${repo_remote_path}/" --config "$RCLONE_CONFIG_PATH"; then
        log "WARN" "Failed to create remote repository directory (may already exist)"
    fi

    # Upload compressed repository archive
    local archive_name=$(basename "$archive_path")
    if rclone copy "$archive_path" "${REMOTE_NAME}:${repo_remote_path}/" --config "$RCLONE_CONFIG_PATH"; then
        log "INFO" "Compressed pgBackRest repository uploaded successfully: $archive_name"
        
        # Clean up local archive
        rm -f "$archive_path"
        
        # For incremental/differential backups, also keep a "latest" copy for easier recovery
        if [[ "$backup_type" != "full" ]]; then
            local latest_name="pgbackrest_repo_latest_${backup_type}.tar.gz"
            if rclone copy "${REMOTE_NAME}:${repo_remote_path}/${archive_name}" "${REMOTE_NAME}:${repo_remote_path}/${latest_name}" --config "$RCLONE_CONFIG_PATH"; then
                log "INFO" "Latest ${backup_type} repository archive updated: $latest_name"
            else
                log "WARN" "Failed to update latest ${backup_type} repository archive"
            fi
        fi
        
        # Return the archive name for use in metadata
        echo "$archive_name"
        return 0
    else
        log "ERROR" "Failed to upload compressed pgBackRest repository"
        rm -f "$archive_path"
        return 1
    fi
}

# Create backup metadata file
create_backup_metadata() {
    local backup_type="$1"
    local output_file="$2"
    local repository_archive="${3:-}"
    local stanza_name="${PGBACKREST_STANZA:-main}"

    # Get backup information
    local backup_info=$(su-exec postgres bash -c "export PGBACKREST_STANZA=\"$stanza_name\" && pgbackrest --stanza=\"$stanza_name\" info --output=json" 2>/dev/null)

    # Create metadata with optional repository archive info
    local metadata_content="{
    \"backup_type\": \"$backup_type\",
    \"stanza\": \"$stanza_name\",
    \"timestamp\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",
    \"database_identifier\": \"$(get_database_identifier)\",
    \"postgres_version\": \"$(su-exec postgres psql -t -c 'SELECT version();' 2>/dev/null | tr -d ' \n')\""

    if [[ -n "$repository_archive" ]]; then
        metadata_content+=",
    \"repository_archive\": \"$repository_archive\",
    \"compression\": \"gzip\""
    fi

    metadata_content+=",
    \"backup_info\": $backup_info
}"

    echo "$metadata_content" > "$output_file"

    log "INFO" "Backup metadata created: $output_file"
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

    # Ensure REMOTE_NAME is set
    if ! ensure_remote_name; then
        log "ERROR" "Failed to determine rclone remote name. Cannot check for existing backups."
        return 1
    fi

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
    # Initialize environment first
    if ! initialize_environment; then
        log "ERROR" "Failed to initialize environment"
        return 1
    fi
    
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

    # Upload to remote storage (full backup directory)
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local db_identifier=$(get_database_identifier)
    local remote_path="${RCLONE_REMOTE_PATH:-postgres-backups}/${db_identifier}/full-backups"
    local remote_filename="pgbackrest_${stanza_name}_${timestamp}.tar.gz"

    if ! compress_and_upload "$archive_path" "$remote_path" "$remote_filename"; then
        log "ERROR" "Failed to upload backup archive"
        rm -f "$archive_path"
        return 1
    fi

    # Also upload pgBackRest repository to common repository directory and get archive name
    local repository_archive=""
    if repository_archive=$(upload_pgbackrest_repository "full"); then
        log "INFO" "pgBackRest repository uploaded successfully"
    else
        log "WARN" "Failed to upload pgBackRest repository"
    fi

    # Clean up local archive
    rm -f "$archive_path"

    # Clean up old backups
    cleanup_old_backups "full"

    log "INFO" "Complete backup process finished successfully"
    return 0
}

# Perform incremental backup
perform_incremental_backup() {
    # Initialize environment first
    if ! initialize_environment; then
        log "ERROR" "Failed to initialize environment"
        return 1
    fi
    
    log "INFO" "Starting incremental backup process..."

    # Configure pgbackrest stanza if not already done
    local stanza_name="${PGBACKREST_STANZA:-main}"
    if ! su-exec postgres bash -c "export PGBACKREST_STANZA=\"$stanza_name\" && pgbackrest --stanza=\"$stanza_name\" info" > /dev/null 2>&1; then
        log "INFO" "Stanza not found, creating stanza..."
        if ! create_pgbackrest_stanza; then
            log "ERROR" "Failed to create pgbackrest stanza"
            return 1
        fi
    fi

    # Check if full backup exists
    if ! check_full_backup_exists; then
        log "WARN" "No full backup found. Performing full backup first..."
        if ! perform_full_backup; then
            log "ERROR" "Failed to perform prerequisite full backup"
            return 1
        fi
        log "INFO" "Full backup completed. Now proceeding with incremental backup..."
    fi

    # Perform pgbackrest incremental backup
    if ! perform_pgbackrest_backup "incr"; then
        log "ERROR" "Pgbackrest incremental backup failed"
        return 1
    fi

    # Upload pgBackRest repository to remote storage and get archive name
    local repository_archive=""
    if repository_archive=$(upload_pgbackrest_repository "incr"); then
        log "INFO" "pgBackRest repository uploaded successfully"
    else
        log "WARN" "Failed to upload pgBackRest repository for incremental backup"
    fi

    # Create and upload backup metadata
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local db_identifier=$(get_database_identifier)
    local metadata_file="/tmp/incremental_backup_${timestamp}.json"
    local remote_path="${RCLONE_REMOTE_PATH:-postgres-backups}/${db_identifier}/incremental-backups"

    if create_backup_metadata "incr" "$metadata_file" "$repository_archive"; then
        # Create remote directory
        if ! rclone mkdir "${REMOTE_NAME}:${remote_path}/" --config "$RCLONE_CONFIG_PATH"; then
            log "WARN" "Failed to create remote incremental directory (may already exist)"
        fi

        # Upload metadata
        if rclone copy "$metadata_file" "${REMOTE_NAME}:${remote_path}/" --config "$RCLONE_CONFIG_PATH"; then
            log "INFO" "Incremental backup metadata uploaded successfully"
        else
            log "WARN" "Failed to upload incremental backup metadata"
        fi

        rm -f "$metadata_file"
    fi

    log "INFO" "Incremental backup completed successfully"
    return 0
}

# Perform differential backup
perform_differential_backup() {
    # Initialize environment first
    if ! initialize_environment; then
        log "ERROR" "Failed to initialize environment"
        return 1
    fi
    
    log "INFO" "Starting differential backup process..."

    # Configure pgbackrest stanza if not already done
    local stanza_name="${PGBACKREST_STANZA:-main}"
    if ! su-exec postgres bash -c "export PGBACKREST_STANZA=\"$stanza_name\" && pgbackrest --stanza=\"$stanza_name\" info" > /dev/null 2>&1; then
        log "INFO" "Stanza not found, creating stanza..."
        if ! create_pgbackrest_stanza; then
            log "ERROR" "Failed to create pgbackrest stanza"
            return 1
        fi
    fi

    # Check if full backup exists
    if ! check_full_backup_exists; then
        log "WARN" "No full backup found. Performing full backup first..."
        if ! perform_full_backup; then
            log "ERROR" "Failed to perform prerequisite full backup"
            return 1
        fi
        log "INFO" "Full backup completed. Now proceeding with differential backup..."
    fi

    # Perform pgbackrest differential backup
    if ! perform_pgbackrest_backup "diff"; then
        log "ERROR" "Pgbackrest differential backup failed"
        return 1
    fi

    # Upload pgBackRest repository to remote storage and get archive name
    local repository_archive=""
    if repository_archive=$(upload_pgbackrest_repository "diff"); then
        log "INFO" "pgBackRest repository uploaded successfully"
    else
        log "WARN" "Failed to upload pgBackRest repository for differential backup"
    fi

    # Create and upload backup metadata
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local db_identifier=$(get_database_identifier)
    local metadata_file="/tmp/differential_backup_${timestamp}.json"
    local remote_path="${RCLONE_REMOTE_PATH:-postgres-backups}/${db_identifier}/differential-backups"

    if create_backup_metadata "diff" "$metadata_file" "$repository_archive"; then
        # Create remote directory
        if ! rclone mkdir "${REMOTE_NAME}:${remote_path}/" --config "$RCLONE_CONFIG_PATH"; then
            log "WARN" "Failed to create remote differential directory (may already exist)"
        fi

        # Upload metadata
        if rclone copy "$metadata_file" "${REMOTE_NAME}:${remote_path}/" --config "$RCLONE_CONFIG_PATH"; then
            log "INFO" "Differential backup metadata uploaded successfully"
        else
            log "WARN" "Failed to upload differential backup metadata"
        fi

        rm -f "$metadata_file"
    fi

    log "INFO" "Differential backup completed successfully"
    return 0
}