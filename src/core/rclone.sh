#!/bin/bash
# rclone configuration and management module

# Setup rclone
setup_rclone() {
    log "INFO" "Setting up rclone..."

    mkdir -p "$(dirname "$RCLONE_CONFIG_PATH")"

    # Check if rclone.conf is already mounted
    if [ -f "$RCLONE_CONFIG_PATH" ] && [ -s "$RCLONE_CONFIG_PATH" ]; then
        log "INFO" "Found mounted rclone configuration file at $RCLONE_CONFIG_PATH"

        # Verify the mounted configuration file
        if ! rclone config show --config "$RCLONE_CONFIG_PATH" >/dev/null 2>&1; then
            log "ERROR" "Mounted rclone configuration file is invalid"
            return 1
        fi

        log "INFO" "Using mounted rclone configuration"

    elif [ -n "$RCLONE_CONF_BASE64" ]; then
        log "INFO" "Using RCLONE_CONF_BASE64 environment variable"

        # Decode and save rclone configuration
        if ! echo "$RCLONE_CONF_BASE64" | base64 -d | tr -d '\r' > "$RCLONE_CONFIG_PATH"; then
            log "ERROR" "Failed to decode RCLONE_CONF_BASE64 or write to $RCLONE_CONFIG_PATH."
            return 1
        fi

        chmod 644 "$RCLONE_CONFIG_PATH"
        log "INFO" "Rclone configuration created from RCLONE_CONF_BASE64 at $RCLONE_CONFIG_PATH."

    else
        log "ERROR" "Neither rclone.conf file nor RCLONE_CONF_BASE64 environment variable provided"
        log "INFO" "Please either:"
        log "INFO" "  1. Mount rclone.conf file to: $RCLONE_CONFIG_PATH"
        log "INFO" "  2. Set RCLONE_CONF_BASE64 environment variable"
        return 1
    fi
    
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
            log "ERROR" "Checking rclone config file contents..."
            if [ -f "$RCLONE_CONFIG_PATH" ]; then
                log "INFO" "Config file exists at: $RCLONE_CONFIG_PATH"
                log "INFO" "Config file contents:"
                cat "$RCLONE_CONFIG_PATH" | head -10
            else
                log "ERROR" "Config file not found at: $RCLONE_CONFIG_PATH"
            fi
            return 1
        fi
    fi
    
    log "INFO" "Final REMOTE_NAME set to: '$REMOTE_NAME'"
    
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

    # Ensure REMOTE_NAME is set
    if ! ensure_remote_name; then
        log "ERROR" "Failed to determine rclone remote name. Cannot upload file."
        return 1
    fi

    if [[ ! -s "$source_file" ]]; then
        log "WARN" "Source file $source_file does not exist or is empty. Skipping upload."
        return 0
    fi

    log "INFO" "Compressing $source_file (size: $(du -h "$source_file" | cut -f1))..."
    temp_compressed_file=$(mktemp --suffix=.gz)
    
    # Ensure cleanup on exit
    trap "rm -f '$temp_compressed_file'" EXIT
    
    # Use gzip with better compression and verification
    if ! gzip -9 -c "$source_file" > "$temp_compressed_file"; then
        log "ERROR" "Failed to compress $source_file."
        rm -f "$temp_compressed_file"
        return 1
    fi

    # Verify the compressed file is not empty
    if [[ ! -s "$temp_compressed_file" ]]; then
        log "ERROR" "Compressed file is empty."
        rm -f "$temp_compressed_file"
        return 1
    fi

    log "INFO" "Verifying compressed file integrity..."
    if ! gzip -t "$temp_compressed_file" 2>/dev/null; then
        log "ERROR" "Compressed file integrity check failed."
        rm -f "$temp_compressed_file"
        return 1
    fi
    
    # Log compression ratio
    local original_size=$(stat -c%s "$source_file")
    local compressed_size=$(stat -c%s "$temp_compressed_file")
    local ratio=$(( (original_size - compressed_size) * 100 / original_size ))
    log "INFO" "Compression successful. Ratio: ${ratio}% ($(du -h "$temp_compressed_file" | cut -f1))"

    log "INFO" "Uploading compressed file to ${remote_path}/${remote_filename}"
    
    # Create remote directory first
    if ! rclone mkdir "${REMOTE_NAME}:${remote_path}/" --config "$RCLONE_CONFIG_PATH"; then
        log "WARN" "Failed to create remote directory (may already exist)"
    fi
    
    # Upload with retry mechanism and verification
    local upload_attempts=3
    local attempt=1
    
    while [ $attempt -le $upload_attempts ]; do
        log "INFO" "Upload attempt $attempt/$upload_attempts"
        
        if rclone copy "$temp_compressed_file" "${REMOTE_NAME}:${remote_path}/" \
            --config "$RCLONE_CONFIG_PATH" \
            --progress \
            --checksum \
            --timeout=300s; then
            
            # Verify upload by checking file size
            local remote_size=$(rclone size "${REMOTE_NAME}:${remote_path}/$(basename "$temp_compressed_file")" --config "$RCLONE_CONFIG_PATH" 2>/dev/null | grep "Total size:" | awk '{print $3}' || echo "0")
            local local_size=$(stat -c%s "$temp_compressed_file")
            
            if [[ "$remote_size" == "$local_size" ]]; then
                log "INFO" "Upload verified successfully"
                break
            else
                log "WARN" "Upload size mismatch (local: $local_size, remote: $remote_size)"
                attempt=$((attempt + 1))
            fi
        else
            log "WARN" "Upload attempt $attempt failed"
            attempt=$((attempt + 1))
            if [ $attempt -le $upload_attempts ]; then
                sleep 5
            fi
        fi
    done
    
    if [ $attempt -gt $upload_attempts ]; then
        log "ERROR" "Failed to upload $source_file after $upload_attempts attempts."
        rm -f "$temp_compressed_file"
        return 1
    fi
    
    # Rename to final filename if needed
    if [[ "$(basename "$temp_compressed_file")" != "$remote_filename" ]]; then
        if ! rclone move "${REMOTE_NAME}:${remote_path}/$(basename "$temp_compressed_file")" "${REMOTE_NAME}:${remote_path}/${remote_filename}" --config "$RCLONE_CONFIG_PATH"; then
            log "ERROR" "Failed to rename uploaded file to $remote_filename"
            rm -f "$temp_compressed_file"
            return 1
        fi
    fi
    
    rm -f "$temp_compressed_file"
    log "INFO" "Successfully uploaded and verified $remote_filename"
    
    # Clear the trap since we've cleaned up manually
    trap - EXIT
}

# Cleanup old backups
cleanup_old_backups() {
    local backup_type="$1"
    local retention_days="${BACKUP_RETENTION_DAYS:-3}"
    local cutoff_date=$(date -d "$retention_days days ago" +%Y%m%d)

    # Ensure REMOTE_NAME is set
    if ! ensure_remote_name; then
        log "ERROR" "Failed to determine rclone remote name. Cannot cleanup old backups."
        return 1
    fi

    local db_identifier=$(get_database_identifier)
    local remote_base_path="${RCLONE_REMOTE_PATH:-postgres-backups}/${db_identifier}"

    # Map backup types to directory names
    local backup_dir
    case "$backup_type" in
        "base"|"full")
            backup_dir="full-backups"
            ;;
        "incr"|"incremental")
            backup_dir="incremental-backups"
            ;;
        "diff"|"differential")
            backup_dir="differential-backups"
            ;;
        *)
            log "WARN" "Unknown backup type '$backup_type'. Skipping cleanup."
            return 0
            ;;
    esac

    log "INFO" "Cleaning up $backup_type backups older than $retention_days days in ${remote_base_path}/${backup_dir}/"

    # Check if the remote directory exists
    if ! rclone lsd "${REMOTE_NAME}:${remote_base_path}/${backup_dir}/" --config "$RCLONE_CONFIG_PATH" > /dev/null 2>&1; then
        log "WARN" "Remote directory ${remote_base_path}/${backup_dir}/ does not exist. Skipping cleanup."
        return 0
    fi

    # Clean up backup files
    rclone lsf "${REMOTE_NAME}:${remote_base_path}/${backup_dir}/" --config "$RCLONE_CONFIG_PATH" | while read -r file; do
        if [[ -z "$file" ]]; then
            continue
        fi

        # Handle different file types
        local file_date=""

        # Support backup archives (YYYYMMDD_HHMMSS.tar.gz)
        if [[ "$file" =~ ([0-9]{8})(_[0-9]{6})?\.tar\.gz$ ]]; then
            file_date="${BASH_REMATCH[1]}"
        # Support metadata files (backup_type_YYYYMMDD_HHMMSS.json)
        elif [[ "$file" =~ ([0-9]{8})_[0-9]{6}\.json$ ]]; then
            file_date="${BASH_REMATCH[1]}"
        fi

        if [[ -n "$file_date" && "$file_date" < "$cutoff_date" ]]; then
            log "INFO" "Deleting old $backup_type backup file: $file"
            rclone delete "${REMOTE_NAME}:${remote_base_path}/${backup_dir}/${file}" --config "$RCLONE_CONFIG_PATH"
        fi
    done

    log "INFO" "Cleanup for ${backup_type} backups completed."
}