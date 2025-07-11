#!/bin/bash
# Environment initialization and management module

# Global variables for environment initialization
ENVIRONMENT_INITIALIZED=false
RCLONE_INITIALIZED=false

# Global variable for the rclone remote name
REMOTE_NAME=""
RCLONE_CONFIG_PATH="/root/.config/rclone/rclone.conf"

# Source environment variables if available
if [[ -f /etc/environment ]]; then
    # Safely source environment variables
    set -a  # automatically export all variables
    source /etc/environment 2>/dev/null || true
    set +a  # disable automatic export
fi

# Initialize environment - this function should be called at the start of any script
initialize_environment() {
    if [[ "$ENVIRONMENT_INITIALIZED" == "true" ]]; then
        return 0
    fi
    
    log "INFO" "Initializing environment..."
    
    # Source environment variables from /etc/environment if available
    if [[ -f /etc/environment ]]; then
        log "INFO" "Loading environment variables from /etc/environment"
        set -a
        source /etc/environment 2>/dev/null || true
        set +a
    fi
    
    # Load configuration file if available
    if command -v load_config_file >/dev/null 2>&1; then
        load_config_file
    fi
    
    # Initialize and validate configuration
    if command -v initialize_config >/dev/null 2>&1; then
        if ! initialize_config; then
            log "ERROR" "Configuration initialization failed"
            return 1
        fi
        # Show configuration summary
        show_config_summary
    else
        # Fallback to legacy environment check
        if ! check_env; then
            log "ERROR" "Environment check failed"
            return 1
        fi
    fi
    
    # Initialize rclone if not already done
    if [[ "$RCLONE_INITIALIZED" != "true" ]]; then
        log "INFO" "Initializing rclone configuration..."
        if ! setup_rclone; then
            log "ERROR" "Failed to setup rclone"
            return 1
        fi
        RCLONE_INITIALIZED=true
    fi
    
    ENVIRONMENT_INITIALIZED=true
    log "INFO" "Environment initialized successfully"
    return 0
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

# Ensure REMOTE_NAME is set (call this before any rclone operations)
ensure_remote_name() {
    # First ensure environment is initialized
    if ! initialize_environment; then
        log "ERROR" "Failed to initialize environment"
        return 1
    fi
    
    if [[ -z "$REMOTE_NAME" ]]; then
        log "ERROR" "REMOTE_NAME is not set after environment initialization"
        log "ERROR" "Please ensure rclone is properly configured"
        return 1
    fi
    
    return 0
}