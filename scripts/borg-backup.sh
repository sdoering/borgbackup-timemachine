#!/bin/bash
# Borg Backup Script with Time Machine-like functionality
# Prevents queue buildup and handles failed backups gracefully

set -euo pipefail

# Source configuration
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/../config/backup.conf"

# Import passphrase
if [[ -f "$HOME/.borg_passphrase" ]]; then
    export BORG_PASSPHRASE="$(cat "$HOME/.borg_passphrase")"
elif [[ -f "$HOME/.config/borg/passphrase" ]]; then
    export BORG_PASSPHRASE="$(cat "$HOME/.config/borg/passphrase")"
else
    echo "Error: No Borg passphrase found"
    exit 1
fi

# Logging function
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_DIR/backup.log"
}

# Check if another backup is running
check_lock() {
    local lock_file="$1"
    local backup_type="$2"
    
    if [[ -f "$lock_file" ]]; then
        local pid=$(cat "$lock_file")
        if kill -0 "$pid" 2>/dev/null; then
            log_message "INFO" "$backup_type backup already running (PID: $pid)"
            return 1
        else
            log_message "WARN" "Stale lock file found, removing"
            rm -f "$lock_file"
        fi
    fi
    
    echo $$ > "$lock_file"
    return 0
}

# Remove lock file
remove_lock() {
    local lock_file="$1"
    rm -f "$lock_file"
}

# Ensure FTP is available and sync repository
ensure_ftp_and_sync() {
    local repo_name="$1"
    local max_retries=3
    local retry=0
    
    while [[ $retry -lt $max_retries ]]; do
        if "$SCRIPT_DIR/mount-ftp.sh" check >/dev/null 2>&1; then
            # Sync repository from FTP to local
            log_message "INFO" "Syncing $repo_name from FTP to local"
            if "$SCRIPT_DIR/mount-ftp.sh" sync-from "$repo_name"; then
                return 0
            else
                log_message "WARN" "Failed to sync from FTP (attempt $((retry + 1)))"
            fi
        else
            log_message "WARN" "FTP not available (attempt $((retry + 1)))"
        fi
        
        ((retry++))
        sleep 5
    done
    
    log_message "ERROR" "Failed to establish FTP connection after $max_retries attempts"
    return 1
}

# Sync repository back to FTP after backup
sync_back_to_ftp() {
    local repo_name="$1"
    
    log_message "INFO" "Syncing $repo_name from local to FTP"
    
    if "$SCRIPT_DIR/mount-ftp.sh" sync-to "$repo_name"; then
        log_message "INFO" "Successfully synced $repo_name to FTP"
        return 0
    else
        log_message "ERROR" "Failed to sync $repo_name back to FTP"
        return 1
    fi
}

# Initialize repository if it doesn't exist
init_repo() {
    local repo_path="$1"
    local repo_name="$2"
    
    if [[ ! -d "$repo_path" ]]; then
        log_message "INFO" "Initializing new repository: $repo_name"
        mkdir -p "$(dirname "$repo_path")"
        borg init --encryption=repokey-blake2 "$repo_path"
        log_message "INFO" "Repository $repo_name initialized successfully"
    fi
}

# Perform backup
perform_backup() {
    local backup_type="$1"
    local sources="$2"
    local repo_path="$3"
    local exclude_file="$4"
    local lock_file="$5"
    
    log_message "INFO" "Starting $backup_type backup"
    
    # Check lock
    if ! check_lock "$lock_file" "$backup_type"; then
        exit 0
    fi
    
    # Ensure cleanup on exit
    trap "remove_lock '$lock_file'" EXIT
    
    # Determine repository name for syncing
    local repo_name
    if [[ "$backup_type" == "home" ]]; then
        repo_name="user-data-repo"
    else
        repo_name="shared-data-repo"
    fi
    
    # Ensure FTP is available and sync repository
    if ! ensure_ftp_and_sync "$repo_name"; then
        log_message "ERROR" "$backup_type backup failed: FTP sync unavailable"
        exit 1
    fi
    
    # Initialize repository if needed
    init_repo "$repo_path" "$backup_type"
    
    # Create backup archive name with timestamp
    local archive_name="${backup_type}-$(date '+%Y-%m-%d_%H-%M-%S')"
    
    # Perform backup
    local backup_cmd=(
        borg create
        --verbose
        --filter AME
        --list
        --stats
        --show-rc
        --compression lz4
        --exclude-caches
    )
    
    if [[ -f "$exclude_file" ]]; then
        backup_cmd+=(--exclude-from "$exclude_file")
    fi
    
    backup_cmd+=("$repo_path::$archive_name" $sources)
    
    log_message "INFO" "Running: ${backup_cmd[*]}"
    
    if "${backup_cmd[@]}" 2>&1 | tee -a "$LOG_DIR/$backup_type-backup.log"; then
        log_message "INFO" "$backup_type backup completed successfully"
        
        # Prune old archives
        prune_archives "$repo_path" "$backup_type"
        
        # Compact repository
        log_message "INFO" "Compacting $backup_type repository"
        borg compact "$repo_path"
        
        # Note: FTP upload is now handled by separate service
        # The FTP upload timer will handle syncing to FTP when appropriate
        log_message "INFO" "$backup_type backup completed, FTP upload will be handled separately"
        
    else
        log_message "ERROR" "$backup_type backup failed"
        exit 1
    fi
}

# Prune old archives (Time Machine-like retention)
prune_archives() {
    local repo_path="$1"
    local backup_type="$2"
    
    log_message "INFO" "Pruning old $backup_type archives"
    
    borg prune \
        --list \
        --prefix "${backup_type}-" \
        --show-rc \
        --keep-hourly $KEEP_HOURLY \
        --keep-daily $KEEP_DAILY \
        --keep-weekly $KEEP_WEEKLY \
        --keep-monthly $KEEP_MONTHLY \
        --keep-yearly $KEEP_YEARLY \
        "$repo_path" 2>&1 | tee -a "$LOG_DIR/$backup_type-prune.log"
}

# Clean old logs
clean_logs() {
    find "$LOG_DIR" -name "*.log" -mtime +$LOG_RETENTION_DAYS -delete 2>/dev/null || true
}

# Main execution
main() {
    local backup_type="$1"
    
    # Create log directory
    mkdir -p "$LOG_DIR"
    
    # Clean old logs
    clean_logs
    
    case "$backup_type" in
        "home")
            perform_backup "home" "$HOME_SOURCES" "$BORG_REPO_BASE/$HOME_REPO" "$HOME_EXCLUDE_FILE" "$HOME_LOCK_FILE"
            ;;
        "shared")
            perform_backup "shared" "$SHARED_SOURCES" "$BORG_REPO_BASE/$SHARED_REPO" "$SHARED_EXCLUDE_FILE" "$SHARED_LOCK_FILE"
            ;;
        "status")
            echo "=== Backup System Status ==="
            "$SCRIPT_DIR/network-check.sh" status
            echo ""
            "$SCRIPT_DIR/mount-ftp.sh" check
            echo ""
            echo "Recent backups:"
            if [[ -f "$LOG_DIR/backup.log" ]]; then
                tail -10 "$LOG_DIR/backup.log"
            else
                echo "No backup log found"
            fi
            ;;
        *)
            echo "Usage: $0 {home|shared|status}"
            exit 1
            ;;
    esac
}

# Check if we're in home network (except for status command)
if [[ "$1" != "status" ]]; then
    if ! "$SCRIPT_DIR/network-check.sh" home >/dev/null 2>&1; then
        log_message "INFO" "Not in home network, skipping backup"
        exit 0
    fi
fi

main "$@"