#!/bin/bash

# WAL Monitor Control Script
# This script provides control over the WAL monitoring service

set -e

source /backup/scripts/backup-functions.sh

WAL_STATE_FILE="/backup/logs/wal-monitor.state"
WAL_LOG_FILE="/backup/logs/wal-monitor.log"
WAL_PID_FILE="/backup/logs/wal-monitor.pid"

# Display usage information
show_usage() {
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "WAL Monitor Control Commands:"
    echo "  start           Start WAL monitoring"
    echo "  stop            Stop WAL monitoring"
    echo "  restart         Restart WAL monitoring"
    echo "  status          Show WAL monitor status"
    echo "  logs            Show WAL monitor logs"
    echo "  reset           Reset WAL monitor state"
    echo "  config          Show current configuration"
    echo "  force-backup    Force an incremental backup now"
    echo ""
    echo "Options:"
    echo "  -f, --follow    Follow logs in real-time (with logs command)"
    echo "  -n, --lines N   Show last N lines of logs (default: 50)"
    echo "  -h, --help      Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 status                    # Check WAL monitor status"
    echo "  $0 logs -n 100              # Show last 100 log lines"
    echo "  $0 logs --follow             # Follow logs in real-time"
    echo "  $0 force-backup              # Trigger backup immediately"
    echo ""
}

# Check if WAL monitor is running
is_wal_monitor_running() {
    if [ -f "$WAL_PID_FILE" ]; then
        local pid=$(cat "$WAL_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        else
            # PID file exists but process is dead, clean up
            rm -f "$WAL_PID_FILE"
            return 1
        fi
    else
        # Check by process name
        if pgrep -f "wal-monitor.sh" >/dev/null; then
            return 0
        else
            return 1
        fi
    fi
}

# Start WAL monitor
start_wal_monitor() {
    if is_wal_monitor_running; then
        echo "WAL monitor is already running"
        return 0
    fi
    
    echo "Starting WAL monitor..."
    /backup/scripts/wal-monitor.sh &
    local pid=$!
    echo "$pid" > "$WAL_PID_FILE"
    
    # Wait a moment to check if it started successfully
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        echo "WAL monitor started successfully (PID: $pid)"
        return 0
    else
        echo "Failed to start WAL monitor"
        rm -f "$WAL_PID_FILE"
        return 1
    fi
}

# Stop WAL monitor
stop_wal_monitor() {
    if ! is_wal_monitor_running; then
        echo "WAL monitor is not running"
        return 0
    fi
    
    echo "Stopping WAL monitor..."
    
    # Try to get PID from file first
    if [ -f "$WAL_PID_FILE" ]; then
        local pid=$(cat "$WAL_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid"
            # Wait for graceful shutdown
            for i in $(seq 1 10); do
                if ! kill -0 "$pid" 2>/dev/null; then
                    break
                fi
                sleep 1
            done
            # Force kill if still running
            if kill -0 "$pid" 2>/dev/null; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$WAL_PID_FILE"
    fi
    
    # Also kill by process name as backup
    pkill -f "wal-monitor.sh" 2>/dev/null || true
    
    echo "WAL monitor stopped"
    return 0
}

# Show WAL monitor status
show_status() {
    echo "=== WAL Monitor Status ==="
    
    if is_wal_monitor_running; then
        echo "Status: RUNNING"
        if [ -f "$WAL_PID_FILE" ]; then
            local pid=$(cat "$WAL_PID_FILE")
            echo "PID: $pid"
        fi
    else
        echo "Status: STOPPED"
    fi
    
    echo ""
    echo "Configuration:"
    echo "  WAL Growth Threshold: ${WAL_GROWTH_THRESHOLD:-100MB}"
    echo "  Monitor Interval: ${WAL_MONITOR_INTERVAL:-60}s"
    echo "  Enable WAL Monitor: ${ENABLE_WAL_MONITOR:-true}"
    
    echo ""
    if [ -f "$WAL_STATE_FILE" ]; then
        echo "Current State:"
        source "$WAL_STATE_FILE"
        echo "  Last Backup Time: ${LAST_BACKUP_TIME:-Never}"
        echo "  Last Backup LSN: ${LAST_BACKUP_LSN:-N/A}"
        echo "  Accumulated WAL Growth: ${ACCUMULATED_WAL_GROWTH:-0} bytes"
    else
        echo "State: No state file found"
    fi
    
    echo ""
    echo "Log Files:"
    echo "  WAL Monitor Log: $WAL_LOG_FILE"
    echo "  State File: $WAL_STATE_FILE"
    if [ -f "$WAL_LOG_FILE" ]; then
        local log_size=$(du -h "$WAL_LOG_FILE" | cut -f1)
        local log_lines=$(wc -l < "$WAL_LOG_FILE")
        echo "  Log Size: $log_size ($log_lines lines)"
    fi
}

# Show logs
show_logs() {
    local lines=50
    local follow=false
    
    # Parse options
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--follow)
                follow=true
                shift
                ;;
            -n|--lines)
                lines="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                return 1
                ;;
        esac
    done
    
    if [ ! -f "$WAL_LOG_FILE" ]; then
        echo "WAL monitor log file not found: $WAL_LOG_FILE"
        return 1
    fi
    
    if [ "$follow" = true ]; then
        echo "Following WAL monitor logs (Ctrl+C to stop)..."
        tail -f "$WAL_LOG_FILE"
    else
        echo "Last $lines lines of WAL monitor logs:"
        tail -n "$lines" "$WAL_LOG_FILE"
    fi
}

# Reset WAL monitor state
reset_state() {
    echo "Resetting WAL monitor state..."
    
    # Stop monitor if running
    if is_wal_monitor_running; then
        echo "Stopping WAL monitor first..."
        stop_wal_monitor
    fi
    
    # Remove state file
    if [ -f "$WAL_STATE_FILE" ]; then
        rm -f "$WAL_STATE_FILE"
        echo "State file removed"
    fi
    
    # Optionally clear logs
    read -p "Clear WAL monitor logs? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        > "$WAL_LOG_FILE"
        echo "Logs cleared"
    fi
    
    echo "WAL monitor state reset complete"
}

# Show current configuration
show_config() {
    echo "=== WAL Monitor Configuration ==="
    echo "Environment Variables:"
    echo "  WAL_GROWTH_THRESHOLD=${WAL_GROWTH_THRESHOLD:-100MB}"
    echo "  WAL_MONITOR_INTERVAL=${WAL_MONITOR_INTERVAL:-60}"
    echo "  ENABLE_WAL_MONITOR=${ENABLE_WAL_MONITOR:-true}"
    echo "  PGBACKREST_STANZA=${PGBACKREST_STANZA:-main}"
    echo "  RCLONE_REMOTE_PATH=${RCLONE_REMOTE_PATH:-postgres-backups}"
    echo ""
    echo "File Paths:"
    echo "  State File: $WAL_STATE_FILE"
    echo "  Log File: $WAL_LOG_FILE"
    echo "  PID File: $WAL_PID_FILE"
}

# Force an incremental backup
force_backup() {
    echo "Forcing incremental backup..."
    
    # Check if PostgreSQL is ready
    if ! wait_for_postgres 10; then
        echo "ERROR: PostgreSQL is not ready"
        return 1
    fi
    
    # Perform incremental backup
    if perform_incremental_backup; then
        echo "Incremental backup completed successfully"
        
        # Update state if WAL monitor is configured
        if [ -f "$WAL_STATE_FILE" ]; then
            source "$WAL_STATE_FILE"
            local current_lsn=$(su-exec postgres psql -t -c "SELECT pg_current_wal_lsn();" 2>/dev/null | tr -d ' ')
            
            # Update state
            cat > "$WAL_STATE_FILE" << EOF
LAST_BACKUP_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
LAST_BACKUP_LSN="$current_lsn"
LAST_CHECK_LSN="$current_lsn"
ACCUMULATED_WAL_GROWTH=0
EOF
            echo "WAL monitor state updated"
        fi
        
        return 0
    else
        echo "ERROR: Incremental backup failed"
        return 1
    fi
}

# Main function
main() {
    local command="$1"
    shift || true
    
    case "$command" in
        start)
            start_wal_monitor
            ;;
        stop)
            stop_wal_monitor
            ;;
        restart)
            stop_wal_monitor
            sleep 2
            start_wal_monitor
            ;;
        status)
            show_status
            ;;
        logs)
            show_logs "$@"
            ;;
        reset)
            reset_state
            ;;
        config)
            show_config
            ;;
        force-backup)
            force_backup
            ;;
        -h|--help|help|"")
            show_usage
            ;;
        *)
            echo "Unknown command: $command"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
