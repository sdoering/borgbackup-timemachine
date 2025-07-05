#!/bin/bash
# Hetzner Storage Box Backup Script
# Runs outside home network when internet is available

set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/../config/backup.conf"

# Hetzner configuration
HETZNER_USER="your_username"  # Replace with your Hetzner username
HETZNER_HOST="your_username.your-storagebox.de"  # Replace with your storage box hostname
HETZNER_REPO_HOME="ssh://$HETZNER_USER@$HETZNER_HOST:23/./borg-repos/home"
HETZNER_REPO_SHARED="ssh://$HETZNER_USER@$HETZNER_HOST:23/./borg-repos/shared"

# SSH key for Hetzner (should be set up beforehand)
HETZNER_SSH_KEY="$HOME/.ssh/hetzner_storagebox"

# Export SSH settings for Borg
export BORG_RSH="ssh -i $HETZNER_SSH_KEY -p 23 -o StrictHostKeyChecking=no"

# Import passphrase (same as local backups)
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
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_DIR/hetzner-backup.log"
}

# Check if internet is available
check_internet() {
    if ! "$SCRIPT_DIR/network-check.sh" internet >/dev/null 2>&1; then
        log_message "INFO" "No internet connection, skipping Hetzner backup"
        exit 0
    fi
}

# Check if we can connect to Hetzner
check_hetzner_connection() {
    if ! ssh -i "$HETZNER_SSH_KEY" -p 23 -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
         "$HETZNER_USER@$HETZNER_HOST" "echo 'Connection test'" >/dev/null 2>&1; then
        log_message "ERROR" "Cannot connect to Hetzner Storage Box"
        return 1
    fi
    return 0
}

# Initialize Hetzner repository
init_hetzner_repo() {
    local repo_path="$1"
    local repo_name="$2"
    
    log_message "INFO" "Checking Hetzner repository: $repo_name"
    
    # Try to access repository info
    if ! borg info "$repo_path" >/dev/null 2>&1; then
        log_message "INFO" "Initializing new Hetzner repository: $repo_name"
        
        # Create directory on Hetzner
        ssh -i "$HETZNER_SSH_KEY" -p 23 "$HETZNER_USER@$HETZNER_HOST" \
            "mkdir -p $(dirname "${repo_path#ssh://$HETZNER_USER@$HETZNER_HOST:23}")"
        
        # Initialize repository
        borg init --encryption=repokey-blake2 "$repo_path"
        log_message "INFO" "Hetzner repository $repo_name initialized successfully"
    fi
}

# Perform Hetzner backup
perform_hetzner_backup() {
    local backup_type="$1"
    local sources="$2"
    local repo_path="$3"
    local exclude_file="$4"
    
    log_message "INFO" "Starting Hetzner $backup_type backup"
    
    # Check connection
    if ! check_hetzner_connection; then
        log_message "ERROR" "Hetzner $backup_type backup failed: connection unavailable"
        exit 1
    fi
    
    # Initialize repository if needed
    init_hetzner_repo "$repo_path" "$backup_type"
    
    # Create backup archive name with timestamp
    local archive_name="hetzner-${backup_type}-$(date '+%Y-%m-%d_%H-%M-%S')"
    
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
    
    log_message "INFO" "Running Hetzner backup: ${backup_cmd[*]}"
    
    if "${backup_cmd[@]}" 2>&1 | tee -a "$LOG_DIR/hetzner-$backup_type-backup.log"; then
        log_message "INFO" "Hetzner $backup_type backup completed successfully"
        
        # Prune old archives
        prune_hetzner_archives "$repo_path" "$backup_type"
        
    else
        log_message "ERROR" "Hetzner $backup_type backup failed"
        exit 1
    fi
}

# Prune Hetzner archives
prune_hetzner_archives() {
    local repo_path="$1"
    local backup_type="$2"
    
    log_message "INFO" "Pruning old Hetzner $backup_type archives"
    
    # More aggressive pruning for offsite backup
    borg prune \
        --list \
        --prefix "hetzner-${backup_type}-" \
        --show-rc \
        --keep-daily 7 \
        --keep-weekly 4 \
        --keep-monthly 12 \
        --keep-yearly 3 \
        "$repo_path" 2>&1 | tee -a "$LOG_DIR/hetzner-$backup_type-prune.log"
}

# Main execution
main() {
    local backup_type="$1"
    
    # Create log directory
    mkdir -p "$LOG_DIR"
    
    # Check internet connection
    check_internet
    
    case "$backup_type" in
        "home")
            perform_hetzner_backup "home" "$HOME_SOURCES" "$HETZNER_REPO_HOME" "$HOME_EXCLUDE_FILE"
            ;;
        "shared")
            perform_hetzner_backup "shared" "$SHARED_SOURCES" "$HETZNER_REPO_SHARED" "$SHARED_EXCLUDE_FILE"
            ;;
        "setup")
            echo "=== Hetzner Storage Box Setup ==="
            echo ""
            echo "1. Generate SSH key for Hetzner:"
            echo "   ssh-keygen -t ed25519 -f ~/.ssh/hetzner_storagebox"
            echo ""
            echo "2. Add public key to Hetzner Storage Box:"
            echo "   cat ~/.ssh/hetzner_storagebox.pub"
            echo "   # Copy this to your Hetzner Robot panel"
            echo ""
            echo "3. Update configuration:"
            echo "   Edit this script and set HETZNER_USER and HETZNER_HOST"
            echo ""
            echo "4. Test connection:"
            echo "   ssh -i ~/.ssh/hetzner_storagebox -p 23 your_username@your_username.your-storagebox.de"
            ;;
        *)
            echo "Usage: $0 {home|shared|setup}"
            exit 1
            ;;
    esac
}

main "$@"