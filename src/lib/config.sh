#!/bin/bash
# Configuration management and validation framework

# Configuration defaults
declare -A CONFIG_DEFAULTS=(
    ["BACKUP_RETENTION_DAYS"]="3"
    ["BASE_BACKUP_SCHEDULE"]="0 3 * * *"
    ["INCREMENTAL_BACKUP_SCHEDULE"]="0 */6 * * *"
    ["RCLONE_REMOTE_PATH"]="postgres-backups"
    ["RECOVERY_MODE"]="false"
    ["PGBACKREST_STANZA"]="main"
    ["WAL_GROWTH_THRESHOLD"]="100MB"
    ["WAL_MONITOR_INTERVAL"]="60"
    ["MIN_WAL_GROWTH_FOR_BACKUP"]="1MB"
    ["ENABLE_WAL_MONITOR"]="true"
    ["RECOVERY_TARGET_INCLUSIVE"]="true"
    ["RECOVERY_TARGET_ACTION"]="promote"
    ["PGDATA"]="/var/lib/postgresql/data"
    ["PGHOST"]="/var/run/postgresql"
    ["PGPORT"]="5432"
)

# Configuration validation rules
declare -A CONFIG_VALIDATION=(
    ["BACKUP_RETENTION_DAYS"]="^[1-9][0-9]*$"
    ["BASE_BACKUP_SCHEDULE"]="^[0-9*,/ -]+$"
    ["INCREMENTAL_BACKUP_SCHEDULE"]="^[0-9*,/ -]+$"
    ["RECOVERY_MODE"]="^(true|false)$"
    ["WAL_MONITOR_INTERVAL"]="^[1-9][0-9]*$"
    ["ENABLE_WAL_MONITOR"]="^(true|false)$"
    ["RECOVERY_TARGET_INCLUSIVE"]="^(true|false)$"
    ["RECOVERY_TARGET_ACTION"]="^(pause|promote|shutdown)$"
    ["PGPORT"]="^[1-9][0-9]{3,4}$"
)

# Required environment variables
REQUIRED_VARS=(
    "POSTGRES_USER"
    "POSTGRES_PASSWORD"
)

# Optional but important variables
IMPORTANT_VARS=(
    "POSTGRES_DB"
    "RCLONE_CONF_BASE64"
    "RCLONE_REMOTE_NAME"
)

# Initialize configuration with validation
initialize_config() {
    log "INFO" "Initializing configuration with validation..."
    
    # Set defaults for undefined variables
    for var in "${!CONFIG_DEFAULTS[@]}"; do
        if [[ -z "${!var}" ]]; then
            declare -g "$var"="${CONFIG_DEFAULTS[$var]}"
            log "INFO" "Set default value for $var: ${CONFIG_DEFAULTS[$var]}"
        fi
    done
    
    # Validate configuration values
    if ! validate_config; then
        log "ERROR" "Configuration validation failed"
        return 1
    fi
    
    # Check required and important variables
    if ! check_required_vars; then
        log "ERROR" "Required variables check failed"
        return 1
    fi
    
    log "INFO" "Configuration initialized and validated successfully"
    return 0
}

# Validate configuration values
validate_config() {
    log "INFO" "Validating configuration values..."
    local validation_failed=false
    
    for var in "${!CONFIG_VALIDATION[@]}"; do
        local value="${!var}"
        local pattern="${CONFIG_VALIDATION[$var]}"
        
        if [[ -n "$value" ]] && ! [[ "$value" =~ $pattern ]]; then
            log "ERROR" "Invalid value for $var: '$value' (expected pattern: $pattern)"
            validation_failed=true
        fi
    done
    
    # Additional custom validations
    if ! validate_size_format "$WAL_GROWTH_THRESHOLD"; then
        log "ERROR" "Invalid WAL_GROWTH_THRESHOLD format: $WAL_GROWTH_THRESHOLD"
        validation_failed=true
    fi
    
    if ! validate_size_format "$MIN_WAL_GROWTH_FOR_BACKUP"; then
        log "ERROR" "Invalid MIN_WAL_GROWTH_FOR_BACKUP format: $MIN_WAL_GROWTH_FOR_BACKUP"
        validation_failed=true
    fi
    
    if [[ "$validation_failed" == "true" ]]; then
        return 1
    fi
    
    log "INFO" "All configuration values are valid"
    return 0
}

# Validate size format (e.g., "100MB", "1GB")
validate_size_format() {
    local size_str="$1"
    [[ "$size_str" =~ ^[0-9]+(\.[0-9]+)?(KB|MB|GB|K|M|G)?$ ]]
}

# Check required variables
check_required_vars() {
    log "INFO" "Checking required environment variables..."
    local missing_vars=()
    
    for var in "${REQUIRED_VARS[@]}"; do
        if [[ -z "${!var}" ]]; then
            missing_vars+=("$var")
            log "ERROR" "Required environment variable not set: $var"
        else
            if [[ "$var" == *"PASSWORD"* ]]; then
                log "INFO" "Required environment variable is set: $var [value hidden]"
            else
                log "INFO" "Required environment variable is set: $var = ${!var}"
            fi
        fi
    done
    
    # Check important variables with warnings
    for var in "${IMPORTANT_VARS[@]}"; do
        if [[ -z "${!var}" ]]; then
            log "WARN" "Important environment variable not set: $var"
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log "ERROR" "Missing required environment variables: ${missing_vars[*]}"
        return 1
    fi
    
    return 0
}

# Load configuration from file if exists
load_config_file() {
    local config_file="${1:-/backup/config/backup.conf}"
    
    if [[ -f "$config_file" ]]; then
        log "INFO" "Loading configuration from: $config_file"
        # Safely source configuration file
        set -a
        source "$config_file"
        set +a
        log "INFO" "Configuration loaded from file"
    else
        log "INFO" "No configuration file found at: $config_file"
    fi
}

# Export configuration summary
show_config_summary() {
    log "INFO" "=== Configuration Summary ==="
    
    # Show non-sensitive configuration
    local non_sensitive_vars=(
        "BACKUP_RETENTION_DAYS"
        "BASE_BACKUP_SCHEDULE"
        "INCREMENTAL_BACKUP_SCHEDULE"
        "RCLONE_REMOTE_PATH"
        "RECOVERY_MODE"
        "PGBACKREST_STANZA"
        "WAL_GROWTH_THRESHOLD"
        "WAL_MONITOR_INTERVAL"
        "MIN_WAL_GROWTH_FOR_BACKUP"
        "ENABLE_WAL_MONITOR"
        "POSTGRES_USER"
        "POSTGRES_DB"
        "PGDATA"
        "PGHOST"
        "PGPORT"
    )
    
    for var in "${non_sensitive_vars[@]}"; do
        log "INFO" "  $var: ${!var}"
    done
    
    # Show sensitive variables status only
    local sensitive_vars=(
        "POSTGRES_PASSWORD"
        "RCLONE_CONF_BASE64"
    )
    
    for var in "${sensitive_vars[@]}"; do
        if [[ -n "${!var}" ]]; then
            log "INFO" "  $var: [SET - hidden for security]"
        else
            log "INFO" "  $var: [NOT SET]"
        fi
    done
    
    log "INFO" "=== End Configuration Summary ==="
}