#!/bin/bash
# Backup System Manager
# Central management script for all backup operations

set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/../config/backup.conf"

# Import passphrase
if [[ -f "$HOME/.borg_passphrase" ]]; then
    export BORG_PASSPHRASE="$(cat "$HOME/.borg_passphrase")"
elif [[ -f "$HOME/.config/borg/passphrase" ]]; then
    export BORG_PASSPHRASE="$(cat "$HOME/.config/borg/passphrase")"
else
    echo "Warning: No Borg passphrase found" >&2
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored output
print_status() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}"
}

# Show system status
show_status() {
    echo "=== Borg Backup System Status ==="
    echo ""
    
    # Network status
    print_status "$BLUE" "Network Status:"
    "$SCRIPT_DIR/network-check.sh" status
    echo ""
    
    # FTP status
    print_status "$BLUE" "FTP Status:"
    if "$SCRIPT_DIR/mount-ftp.sh" check >/dev/null 2>&1; then
        print_status "$GREEN" "✓ FTP backup storage accessible"
    else
        print_status "$RED" "✗ FTP backup storage not accessible"
    fi
    echo ""
    
    # Timer status
    print_status "$BLUE" "Backup Timers:"
    systemctl --user list-timers | grep -E "(borgbackup|ftp-upload)" || echo "No backup timers found"
    echo ""
    
    # Recent backup status
    print_status "$BLUE" "Recent Backup Activity:"
    if [[ -f "$LOG_DIR/backup.log" ]]; then
        tail -5 "$LOG_DIR/backup.log"
    else
        print_status "$YELLOW" "No backup log found"
    fi
    echo ""
    
    # FTP Upload status
    print_status "$BLUE" "FTP Upload Status:"
    if [[ -f "$LOG_DIR/ftp-upload.log" ]]; then
        tail -3 "$LOG_DIR/ftp-upload.log"
    else
        print_status "$YELLOW" "No FTP upload log found"
    fi
    echo ""
    
    # Repository info
    print_status "$BLUE" "Repository Information:"
    show_repo_info
}

# Show repository information
show_repo_info() {
    local mount_available=false
    
    # Check if FTP is available
    if "$SCRIPT_DIR/mount-ftp.sh" check >/dev/null 2>&1; then
        mount_available=true
    fi
    
    if $mount_available; then
        for repo in "$HOME_REPO" "$SHARED_REPO"; do
            local repo_path="$BORG_REPO_BASE/$repo"
            if [[ -d "$repo_path" ]]; then
                print_status "$GREEN" "Repository: $repo"
                
                # Get repository statistics
                local repo_stats=$(borg info "$repo_path" 2>/dev/null | grep -A 3 "All archives:" || echo "Statistics not available")
                if [[ "$repo_stats" != "Statistics not available" ]]; then
                    echo "$repo_stats"
                else
                    echo "Repository size information not available"
                fi
                
                echo "Recent archives:"
                borg list "$repo_path" 2>/dev/null | tail -3 || echo "No archives found"
                echo ""
            else
                print_status "$YELLOW" "Repository $repo not found at $repo_path"
            fi
        done
    else
        print_status "$YELLOW" "Cannot check repositories - FTP not available"
    fi
}

# Force backup now
force_backup() {
    local backup_type="$1"
    
    print_status "$BLUE" "Forcing $backup_type backup..."
    
    # Remove lock file if it exists
    case "$backup_type" in
        "home")
            rm -f "$HOME_LOCK_FILE"
            ;;
        "shared")
            rm -f "$SHARED_LOCK_FILE"
            ;;
    esac
    
    # Run backup
    "$SCRIPT_DIR/borg-backup.sh" "$backup_type"
}

# Show backup logs
show_logs() {
    local log_type="$1"
    local log_file="$LOG_DIR/$log_type"
    
    if [[ -f "$log_file" ]]; then
        tail -20 "$log_file"
    else
        print_status "$YELLOW" "Log file not found: $log_file"
    fi
}

# List available archives
list_archives() {
    local repo="$1"
    local repo_path="$BORG_REPO_BASE/$repo"
    
    if ! "$SCRIPT_DIR/mount-ftp.sh" check >/dev/null 2>&1; then
        print_status "$RED" "FTP not available"
        return 1
    fi
    
    if [[ -d "$repo_path" ]]; then
        print_status "$BLUE" "Archives in $repo repository:"
        borg list "$repo_path"
    else
        print_status "$YELLOW" "Repository $repo not found"
    fi
}

# Manage FTP operations
manage_ftp() {
    local action="$1"
    "$SCRIPT_DIR/mount-ftp.sh" "$action"
}

# Control timers
manage_timers() {
    local action="$1"
    
    case "$action" in
        "enable")
            systemctl --user enable borgbackup-home.timer
            systemctl --user enable borgbackup-shared.timer
            systemctl --user start borgbackup-home.timer
            systemctl --user start borgbackup-shared.timer
            print_status "$GREEN" "Backup timers enabled and started"
            ;;
        "disable")
            systemctl --user stop borgbackup-home.timer
            systemctl --user stop borgbackup-shared.timer
            systemctl --user disable borgbackup-home.timer
            systemctl --user disable borgbackup-shared.timer
            print_status "$YELLOW" "Backup timers stopped and disabled"
            ;;
        "restart")
            systemctl --user restart borgbackup-home.timer
            systemctl --user restart borgbackup-shared.timer
            print_status "$GREEN" "Backup timers restarted"
            ;;
        *)
            echo "Usage: timers {enable|disable|restart}"
            ;;
    esac
}

# Show help
show_help() {
    echo "Borg Backup System Manager"
    echo ""
    echo "Usage: $0 COMMAND [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  status                Show system status"
    echo "  backup home          Force home directory backup"
    echo "  backup shared        Force shared partition backup"
    echo "  ftp {setup|test|check}    Manage FTP connection"
    echo "  timers {enable|disable|restart}  Manage backup timers
  ftp-status               Show detailed FTP upload status"
    echo "  logs backup          Show main backup log"
    echo "  logs home            Show home backup log"
    echo "  logs shared          Show shared backup log"
    echo "  list home            List home repository archives"
    echo "  list shared          List shared repository archives"
    echo "  install              Install backup system"
    echo "  help                 Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 status            # Check system status"
    echo "  $0 backup home       # Force home backup now"
    echo "  $0 ftp setup         # Setup FTP connection"
    echo "  $0 timers enable     # Enable automatic backups"
}

# Main execution
case "${1:-help}" in
    "status")
        show_status
        ;;
    "backup")
        if [[ -n "${2:-}" ]]; then
            force_backup "$2"
        else
            echo "Usage: $0 backup {home|shared}"
        fi
        ;;
    "ftp")
        if [[ -n "${2:-}" ]]; then
            manage_ftp "$2"
        else
            echo "Usage: $0 ftp {setup|test|check}"
        fi
        ;;
    "timers")
        if [[ -n "${2:-}" ]]; then
            manage_timers "$2"
        else
            echo "Usage: $0 timers {enable|disable|restart}"
        fi
        ;;
    "logs")
        if [[ -n "${2:-}" ]]; then
            show_logs "${2}-backup.log"
        else
            show_logs "backup.log"
        fi
        ;;
    "list")
        if [[ -n "${2:-}" ]]; then
            case "$2" in
                "home")
                    list_archives "user-data-repo"
                    ;;
                "shared")
                    list_archives "shared-data-repo"
                    ;;
                *)
                    echo "Usage: $0 list {home|shared}"
                    ;;
            esac
        else
            echo "Usage: $0 list {home|shared}"
        fi
        ;;
    "install")
        "$SCRIPT_DIR/install-backup-system.sh"
        ;;
    "ftp-status")
        "$SCRIPT_DIR/ftp-upload.sh" status
        ;;
    "help"|*)
        show_help
        ;;
esac