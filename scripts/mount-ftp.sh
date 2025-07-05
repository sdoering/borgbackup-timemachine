#!/bin/bash
# FTP Access Script for Borg Backup
# Uses lftp for reliable FTP operations without mounting

source "$(dirname "$0")/../config/backup.conf"

CREDENTIALS_FILE="$HOME/.local/borgbackup/config/ftp-credentials"

# Create credentials file if it doesn't exist
create_credentials_file() {
    if [[ ! -f "$CREDENTIALS_FILE" ]]; then
        cat > "$CREDENTIALS_FILE" << EOF
user=$FTP_USER
# Add password here manually:
# pass=your_password_here
EOF
        chmod 600 "$CREDENTIALS_FILE"
        echo "Created credentials file at $CREDENTIALS_FILE"
        echo "Please add your FTP password manually to this file."
        echo "Format: pass=your_password_here"
        exit 1
    fi
}

# Check if lftp is installed
check_dependencies() {
    if ! command -v lftp >/dev/null 2>&1; then
        echo "Error: lftp not installed. Install with:"
        echo "sudo apt install lftp"
        exit 1
    fi
}

# Get FTP credentials
get_ftp_credentials() {
    if [[ ! -f "$CREDENTIALS_FILE" ]]; then
        create_credentials_file
        return 1
    fi
    
    FTP_PASSWORD=$(grep '^pass=' "$CREDENTIALS_FILE" | cut -d'=' -f2)
    if [[ -z "$FTP_PASSWORD" ]]; then
        echo "Error: No password found in credentials file"
        echo "Please add: pass=your_password_here to $CREDENTIALS_FILE"
        return 1
    fi
    return 0
}

# Test FTP connection
test_ftp() {
    if ! get_ftp_credentials; then
        return 1
    fi
    
    echo "Testing FTP connection to $FTP_HOST..."
    
    lftp -c "
    set ftp:ssl-allow no
    open ftp://$FTP_USER:$FTP_PASSWORD@$FTP_HOST
    cd borgbackup 2>/dev/null || mkdir borgbackup
    ls BorgBackup 2>/dev/null || mkdir BorgBackup
    quit
    " 2>/dev/null
    
    if [[ $? -eq 0 ]]; then
        echo "FTP connection successful"
        return 0
    else
        echo "FTP connection failed"
        return 1
    fi
}

# Create directory structure on FTP
setup_ftp_structure() {
    if ! get_ftp_credentials; then
        return 1
    fi
    
    echo "Setting up FTP directory structure..."
    
    lftp -c "
    set ftp:ssl-allow no
    open ftp://$FTP_USER:$FTP_PASSWORD@$FTP_HOST
    cd borgbackup 2>/dev/null || mkdir borgbackup
    cd borgbackup
    ls BorgBackup 2>/dev/null || mkdir BorgBackup
    cd BorgBackup
    ls user-data-repo 2>/dev/null || mkdir user-data-repo
    ls shared-data-repo 2>/dev/null || mkdir shared-data-repo
    quit
    " 2>/dev/null
    
    if [[ $? -eq 0 ]]; then
        echo "FTP directory structure created"
        return 0
    else
        echo "Failed to create FTP directory structure"
        return 1
    fi
}

# Create local mirror directory (for borg to work with)
setup_local_mirror() {
    mkdir -p "$FTP_MOUNT_POINT/BorgBackup"
    echo "Local mirror directory created at $FTP_MOUNT_POINT"
}

# Sync from FTP to local (before backup)
sync_from_ftp() {
    local repo_name="$1"
    
    if ! get_ftp_credentials; then
        return 1
    fi
    
    echo "Syncing $repo_name from FTP..."
    
    local local_repo="$FTP_MOUNT_POINT/$repo_name"
    mkdir -p "$local_repo"
    
    lftp -c "
    set ftp:ssl-allow no
    open ftp://$FTP_USER:$FTP_PASSWORD@$FTP_HOST
    cd borgbackup/BorgBackup/$repo_name 2>/dev/null || exit 0
    mirror --verbose --use-cache --parallel=2 . $local_repo
    quit
    " 2>/dev/null
    
    return $?
}

# Sync from local to FTP (after backup)
sync_to_ftp() {
    local repo_name="$1"
    
    if ! get_ftp_credentials; then
        return 1
    fi
    
    echo "Syncing $repo_name to FTP..."
    
    local local_repo="$FTP_MOUNT_POINT/$repo_name"
    
    if [[ ! -d "$local_repo" ]]; then
        echo "Error: Local repository not found: $local_repo"
        return 1
    fi
    
    echo "Syncing from: $local_repo"
    echo "To FTP path: borgbackup/BorgBackup/$repo_name"
    
    lftp -c "
    set ftp:ssl-allow no
    open ftp://$FTP_USER:$FTP_PASSWORD@$FTP_HOST
    cd borgbackup
    ls BorgBackup 2>/dev/null || mkdir BorgBackup
    cd BorgBackup
    mirror --verbose --reverse --use-cache --parallel=2 --delete $local_repo $repo_name
    quit
    "
    
    return $?
}

# Check if FTP is accessible
check_ftp() {
    echo "Checking FTP accessibility..."
    test_ftp
}

case "$1" in
    "setup")
        check_dependencies
        create_credentials_file
        setup_ftp_structure
        setup_local_mirror
        ;;
    "test")
        check_dependencies
        test_ftp
        ;;
    "check")
        check_ftp
        ;;
    "sync-from")
        if [[ -n "${2:-}" ]]; then
            sync_from_ftp "$2"
        else
            echo "Usage: $0 sync-from {user-data-repo|shared-data-repo}"
        fi
        ;;
    "sync-to")
        if [[ -n "${2:-}" ]]; then
            sync_to_ftp "$2"
        else
            echo "Usage: $0 sync-to {user-data-repo|shared-data-repo}"
        fi
        ;;
    *)
        echo "Usage: $0 {setup|test|check|sync-from|sync-to}"
        echo ""
        echo "Commands:"
        echo "  setup                 Setup FTP credentials and directory structure"
        echo "  test                  Test FTP connection"
        echo "  check                 Check if FTP is accessible"
        echo "  sync-from REPO        Sync repository from FTP to local"
        echo "  sync-to REPO          Sync repository from local to FTP"
        exit 1
        ;;
esac