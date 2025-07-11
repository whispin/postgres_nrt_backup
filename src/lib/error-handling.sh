#!/bin/bash
# Error handling and retry mechanism module

# Error codes
declare -A ERROR_CODES=(
    ["SUCCESS"]=0
    ["GENERAL_ERROR"]=1
    ["ENVIRONMENT_ERROR"]=10
    ["CONFIG_ERROR"]=11
    ["POSTGRES_ERROR"]=20
    ["PGBACKREST_ERROR"]=21
    ["RCLONE_ERROR"]=30
    ["NETWORK_ERROR"]=31
    ["BACKUP_ERROR"]=40
    ["RECOVERY_ERROR"]=50
    ["VALIDATION_ERROR"]=60
)

# Global error context
ERROR_CONTEXT=""

# Set error context for better error reporting
set_error_context() {
    ERROR_CONTEXT="$1"
}

# Clear error context
clear_error_context() {
    ERROR_CONTEXT=""
}

# Enhanced error logging with context
log_error() {
    local error_code="$1"
    local error_message="$2"
    local context="${ERROR_CONTEXT:-Unknown}"
    
    log "ERROR" "[$context] $error_message (Error Code: $error_code)"
    
    # Log stack trace if available
    if [[ "${BASH_VERSION%%.*}" -ge 4 ]]; then
        local frame=0
        log "ERROR" "Call stack:"
        while caller $frame; do
            ((frame++))
        done 2>/dev/null | while read line func file; do
            log "ERROR" "  at $func() in $file:$line"
        done
    fi
}

# Retry mechanism with exponential backoff
retry_with_backoff() {
    local max_attempts="$1"
    local base_delay="$2"
    local max_delay="${3:-60}"
    shift 3
    local command=("$@")
    
    local attempt=1
    local delay="$base_delay"
    
    while [ $attempt -le $max_attempts ]; do
        log "INFO" "Attempt $attempt/$max_attempts: ${command[*]}"
        
        if "${command[@]}"; then
            if [ $attempt -gt 1 ]; then
                log "INFO" "Command succeeded on attempt $attempt"
            fi
            return 0
        fi
        
        local exit_code=$?
        
        if [ $attempt -eq $max_attempts ]; then
            log_error "$exit_code" "Command failed after $max_attempts attempts: ${command[*]}"
            return $exit_code
        fi
        
        log "WARN" "Command failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
        sleep "$delay"
        
        # Exponential backoff with jitter
        delay=$(( delay * 2 ))
        if [ $delay -gt $max_delay ]; then
            delay=$max_delay
        fi
        
        # Add jitter (±20%)
        local jitter=$(( delay / 5 ))
        local random_jitter=$(( (RANDOM % (jitter * 2)) - jitter ))
        delay=$(( delay + random_jitter ))
        
        ((attempt++))
    done
}

# Network operation with retry
network_retry() {
    local operation="$1"
    shift
    
    set_error_context "Network Operation: $operation"
    
    # Network operations typically need more retries with shorter delays
    retry_with_backoff 5 2 30 "$@"
    local result=$?
    
    clear_error_context
    return $result
}

# Database operation with retry
database_retry() {
    local operation="$1"
    shift
    
    set_error_context "Database Operation: $operation"
    
    # Database operations need fewer retries but longer delays
    retry_with_backoff 3 5 60 "$@"
    local result=$?
    
    clear_error_context
    return $result
}

# File operation with retry
file_retry() {
    local operation="$1"
    shift
    
    set_error_context "File Operation: $operation"
    
    # File operations usually fail quickly, so shorter delays
    retry_with_backoff 3 1 10 "$@"
    local result=$?
    
    clear_error_context
    return $result
}

# Graceful error handling with cleanup
handle_error() {
    local exit_code="$1"
    local error_message="$2"
    local cleanup_function="${3:-}"
    
    log_error "$exit_code" "$error_message"
    
    # Execute cleanup function if provided
    if [[ -n "$cleanup_function" ]] && declare -f "$cleanup_function" > /dev/null; then
        log "INFO" "Executing cleanup function: $cleanup_function"
        if ! "$cleanup_function"; then
            log "WARN" "Cleanup function failed, but continuing with error handling"
        fi
    fi
    
    # Exit with the error code
    exit "$exit_code"
}

# Validate critical prerequisites before operation
validate_prerequisites() {
    local operation="$1"
    shift
    local prerequisites=("$@")
    
    log "INFO" "Validating prerequisites for: $operation"
    
    for prereq in "${prerequisites[@]}"; do
        case "$prereq" in
            "postgres")
                if ! wait_for_postgres 30; then
                    log_error "${ERROR_CODES[POSTGRES_ERROR]}" "PostgreSQL is not available"
                    return "${ERROR_CODES[POSTGRES_ERROR]}"
                fi
                ;;
            "rclone")
                if ! command -v rclone >/dev/null 2>&1; then
                    log_error "${ERROR_CODES[RCLONE_ERROR]}" "rclone command not found"
                    return "${ERROR_CODES[RCLONE_ERROR]}"
                fi
                ;;
            "pgbackrest")
                if ! command -v pgbackrest >/dev/null 2>&1; then
                    log_error "${ERROR_CODES[PGBACKREST_ERROR]}" "pgbackrest command not found"
                    return "${ERROR_CODES[PGBACKREST_ERROR]}"
                fi
                ;;
            "environment")
                if ! initialize_environment; then
                    log_error "${ERROR_CODES[ENVIRONMENT_ERROR]}" "Environment initialization failed"
                    return "${ERROR_CODES[ENVIRONMENT_ERROR]}"
                fi
                ;;
            *)
                log "WARN" "Unknown prerequisite: $prereq"
                ;;
        esac
    done
    
    log "INFO" "All prerequisites validated for: $operation"
    return 0
}

# Wrapper for critical operations with error handling
execute_critical_operation() {
    local operation_name="$1"
    local cleanup_function="$2"
    shift 2
    local command=("$@")
    
    set_error_context "$operation_name"
    
    log "INFO" "Starting critical operation: $operation_name"
    
    # Execute the command
    if "${command[@]}"; then
        log "INFO" "Critical operation completed successfully: $operation_name"
        clear_error_context
        return 0
    else
        local exit_code=$?
        handle_error "$exit_code" "Critical operation failed: $operation_name" "$cleanup_function"
    fi
}

# Safe file operations with atomic writes
safe_file_write() {
    local target_file="$1"
    local content="$2"
    local temp_file="${target_file}.tmp.$$"
    
    # Write to temporary file first
    if echo "$content" > "$temp_file"; then
        # Atomic move to target file
        if mv "$temp_file" "$target_file"; then
            log "INFO" "File written safely: $target_file"
            return 0
        else
            log_error "${ERROR_CODES[GENERAL_ERROR]}" "Failed to move temporary file to target: $target_file"
            rm -f "$temp_file"
            return "${ERROR_CODES[GENERAL_ERROR]}"
        fi
    else
        log_error "${ERROR_CODES[GENERAL_ERROR]}" "Failed to write to temporary file: $temp_file"
        rm -f "$temp_file"
        return "${ERROR_CODES[GENERAL_ERROR]}"
    fi
}

# Resource monitoring and alerts
monitor_resource_usage() {
    local operation="$1"
    local disk_threshold="${2:-90}"  # Disk usage threshold in percentage
    local memory_threshold="${3:-90}"  # Memory usage threshold in percentage
    
    # Check disk usage
    local disk_usage=$(df /backup 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//')
    if [[ "$disk_usage" -gt "$disk_threshold" ]]; then
        log "WARN" "High disk usage during $operation: ${disk_usage}% (threshold: ${disk_threshold}%)"
    fi
    
    # Check memory usage
    local memory_usage=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100.0}')
    if [[ "$memory_usage" -gt "$memory_threshold" ]]; then
        log "WARN" "High memory usage during $operation: ${memory_usage}% (threshold: ${memory_threshold}%)"
    fi
}

# Export error handling functions
export -f set_error_context
export -f clear_error_context
export -f log_error
export -f retry_with_backoff
export -f network_retry
export -f database_retry
export -f file_retry
export -f handle_error
export -f validate_prerequisites
export -f execute_critical_operation
export -f safe_file_write
export -f monitor_resource_usage