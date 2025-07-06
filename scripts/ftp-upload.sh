#!/bin/bash
# Separate FTP Upload Script for Borg Backup Repositories
# Handles uploading local backup repositories to FTP when system is active

set -euo pipefail

# Source configuration
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/../config/backup.conf"

# FTP Upload Lock files
FTP_UPLOAD_LOCK_DIR="$HOME/.local/borgbackup/locks"
FTP_UPLOAD_LOCK_FILE="$FTP_UPLOAD_LOCK_DIR/ftp-upload.lock"

# Logging function
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_DIR/ftp-upload.log"
}

# Check if another upload is running
check_upload_lock() {
    mkdir -p "$FTP_UPLOAD_LOCK_DIR"
    
    if [[ -f "$FTP_UPLOAD_LOCK_FILE" ]]; then
        local pid=$(cat "$FTP_UPLOAD_LOCK_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log_message "INFO" "FTP upload already running (PID: $pid)"
            return 1
        else
            log_message "WARN" "Stale FTP upload lock file found, removing"
            rm -f "$FTP_UPLOAD_LOCK_FILE"
        fi
    fi
    
    echo $$ > "$FTP_UPLOAD_LOCK_FILE"
    return 0
}

# Remove upload lock file
remove_upload_lock() {
    rm -f "$FTP_UPLOAD_LOCK_FILE"
}

# Check if repository needs upload (has been modified recently)
needs_upload() {
    local repo_path="$1"
    local repo_name="$2"
    local upload_marker_file="$HOME/.local/borgbackup/logs/last-upload-$repo_name"
    
    if [[ ! -d "$repo_path" ]]; then
        log_message "DEBUG" "Repository $repo_name not found at $repo_path"
        return 1
    fi
    
    # Get the last modification time of the repository
    local repo_mtime=$(find "$repo_path" -type f -name "index.*" -o -name "integrity.*" | head -1 | xargs stat -c %Y 2>/dev/null || echo 0)
    
    # Get the last upload time
    local last_upload=0
    if [[ -f "$upload_marker_file" ]]; then
        last_upload=$(cat "$upload_marker_file")
    fi
    
    if [[ $repo_mtime -gt $last_upload ]]; then
        log_message "DEBUG" "Repository $repo_name needs upload (modified: $repo_mtime, last upload: $last_upload)"
        return 0
    else
        log_message "DEBUG" "Repository $repo_name up to date"
        return 1
    fi
}

# Mark repository as uploaded
mark_uploaded() {
    local repo_name="$1"
    local upload_marker_file="$HOME/.local/borgbackup/logs/last-upload-$repo_name"
    
    echo "$(date +%s)" > "$upload_marker_file"
}

# Upload repository to FTP
upload_to_ftp() {
    local repo_name="$1"
    local repo_path="$2"
    
    log_message "INFO" "Starting FTP upload for $repo_name"
    
    if ! needs_upload "$repo_path" "$repo_name"; then
        log_message "INFO" "Repository $repo_name already up to date, skipping upload"
        return 0
    fi
    
    # Check if repository is currently being used (has active lock)
    local backup_lock_file
    if [[ "$repo_name" == "user-data-repo" ]]; then
        backup_lock_file="$HOME_LOCK_FILE"
    else
        backup_lock_file="$SHARED_LOCK_FILE"
    fi
    
    if [[ -f "$backup_lock_file" ]]; then
        local backup_pid=$(cat "$backup_lock_file")
        if kill -0 "$backup_pid" 2>/dev/null; then
            log_message "INFO" "Repository $repo_name is currently being backed up, skipping upload"
            return 0
        fi
    fi
    
    # Perform the upload
    log_message "INFO" "Uploading $repo_name to FTP..."
    
    if "$SCRIPT_DIR/mount-ftp.sh" sync-to "$repo_name"; then
        log_message "INFO" "Successfully uploaded $repo_name to FTP"
        mark_uploaded "$repo_name"
        return 0
    else
        log_message "ERROR" "Failed to upload $repo_name to FTP"
        return 1
    fi
}

# Check prerequisites
check_prerequisites() {
    # Check if we're in home network
    if ! "$SCRIPT_DIR/network-check.sh" home >/dev/null 2>&1; then
        log_message "INFO" "Not in home network, skipping FTP upload"
        return 1
    fi
    
    # Check if FTP is available
    if ! "$SCRIPT_DIR/mount-ftp.sh" check >/dev/null 2>&1; then
        log_message "WARN" "FTP not available, skipping upload"
        return 1
    fi
    
    # Check if on AC power (optional, can be disabled)
    if command -v on_ac_power >/dev/null 2>&1; then
        if ! on_ac_power; then
            log_message "INFO" "On battery power, skipping FTP upload to preserve battery"
            return 1
        fi
    fi
    
    return 0
}

# Upload all repositories that need it
upload_all() {
    local uploaded_count=0
    local failed_count=0
    
    log_message "INFO" "Starting FTP upload check for all repositories"
    
    # Check prerequisites
    if ! check_prerequisites; then
        return 0
    fi
    
    # Check and upload user-data-repo
    if upload_to_ftp "user-data-repo" "$BORG_REPO_BASE/$HOME_REPO"; then
        ((uploaded_count++))
    else
        ((failed_count++))
    fi
    
    # Check and upload shared-data-repo
    if upload_to_ftp "shared-data-repo" "$BORG_REPO_BASE/$SHARED_REPO"; then
        ((uploaded_count++))
    else
        ((failed_count++))
    fi
    
    if [[ $uploaded_count -gt 0 ]]; then
        log_message "INFO" "FTP upload completed: $uploaded_count uploaded, $failed_count failed"
    else
        log_message "DEBUG" "No repositories needed uploading"
    fi
    
    return $failed_count
}

# Force upload specific repository
force_upload() {
    local repo_name="$1"
    local repo_path
    
    case "$repo_name" in
        "user-data-repo")
            repo_path="$BORG_REPO_BASE/$HOME_REPO"
            ;;
        "shared-data-repo")
            repo_path="$BORG_REPO_BASE/$SHARED_REPO"
            ;;
        *)
            log_message "ERROR" "Unknown repository: $repo_name"
            return 1
            ;;
    esac
    
    log_message "INFO" "Force uploading $repo_name"
    
    # Remove upload marker to force upload
    local upload_marker_file="$HOME/.local/borgbackup/logs/last-upload-$repo_name"
    rm -f "$upload_marker_file"
    
    if upload_to_ftp "$repo_name" "$repo_path"; then
        log_message "INFO" "Force upload of $repo_name completed successfully"
        return 0
    else
        log_message "ERROR" "Force upload of $repo_name failed"
        return 1
    fi
}

# Show upload status
show_status() {
    echo "=== FTP Upload Status ==="
    echo ""
    
    # Check prerequisites
    echo "Prerequisites:"
    if "$SCRIPT_DIR/network-check.sh" home >/dev/null 2>&1; then
        echo "  ✓ In home network"
    else
        echo "  ✗ Not in home network"
    fi
    
    if "$SCRIPT_DIR/mount-ftp.sh" check >/dev/null 2>&1; then
        echo "  ✓ FTP accessible"
    else
        echo "  ✗ FTP not accessible"
    fi
    
    if command -v on_ac_power >/dev/null 2>&1; then
        if on_ac_power; then
            echo "  ✓ On AC power"
        else
            echo "  ✗ On battery power"
        fi
    else
        echo "  ? AC power status unknown"
    fi
    
    echo ""
    echo "Repository Status:"
    
    # Check each repository
    for repo_name in "user-data-repo" "shared-data-repo"; do
        local repo_path
        if [[ "$repo_name" == "user-data-repo" ]]; then
            repo_path="$BORG_REPO_BASE/$HOME_REPO"
        else
            repo_path="$BORG_REPO_BASE/$SHARED_REPO"
        fi
        
        local upload_marker_file="$HOME/.local/borgbackup/logs/last-upload-$repo_name"
        
        echo "  $repo_name:"
        if [[ -d "$repo_path" ]]; then
            echo "    ✓ Repository exists"
            
            if [[ -f "$upload_marker_file" ]]; then
                local last_upload=$(cat "$upload_marker_file")
                local last_upload_date=$(date -d "@$last_upload" 2>/dev/null || echo "Unknown")
                echo "    ✓ Last upload: $last_upload_date"
            else
                echo "    ✗ Never uploaded"
            fi
            
            if needs_upload "$repo_path" "$repo_name"; then
                echo "    ⚠ Needs upload"
            else
                echo "    ✓ Up to date"
            fi
        else
            echo "    ✗ Repository not found"
        fi
        echo ""
    done
    
    # Show recent upload log
    echo "Recent upload activity:"
    if [[ -f "$LOG_DIR/ftp-upload.log" ]]; then
        tail -5 "$LOG_DIR/ftp-upload.log"
    else
        echo "  No upload log found"
    fi
}

# Clean old upload logs
clean_logs() {
    find "$LOG_DIR" -name "ftp-upload.log" -mtime +$LOG_RETENTION_DAYS -delete 2>/dev/null || true
}

# Main execution
main() {
    local action="${1:-upload}"
    
    # Create log directory
    mkdir -p "$LOG_DIR"
    
    # Clean old logs
    clean_logs
    
    case "$action" in
        "upload")
            # Check upload lock
            if ! check_upload_lock; then
                exit 0
            fi
            
            # Ensure cleanup on exit
            trap remove_upload_lock EXIT
            
            upload_all
            ;;
        "force")
            local repo_name="${2:-}"
            if [[ -z "$repo_name" ]]; then
                echo "Usage: $0 force {user-data-repo|shared-data-repo}"
                exit 1
            fi
            
            # Check upload lock
            if ! check_upload_lock; then
                exit 0
            fi
            
            # Ensure cleanup on exit
            trap remove_upload_lock EXIT
            
            force_upload "$repo_name"
            ;;
        "status")
            show_status
            ;;
        *)
            echo "Usage: $0 {upload|force|status}"
            echo ""
            echo "Commands:"
            echo "  upload                Upload repositories that need it"
            echo "  force REPO            Force upload specific repository"
            echo "  status                Show upload status"
            exit 1
            ;;
    esac
}

main "$@"