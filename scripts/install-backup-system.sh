#!/bin/bash
# Installation script for the Borg Backup System

set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
CONFIG_DIR="$SCRIPT_DIR/../config"

echo "=== Installing Borg Backup System ==="

# Check dependencies
echo "Checking dependencies..."
missing_deps=()

if ! command -v borg >/dev/null 2>&1; then
    missing_deps+=("borgbackup")
fi

if ! command -v lftp >/dev/null 2>&1; then
    missing_deps+=("lftp")
fi

if [[ ${#missing_deps[@]} -gt 0 ]]; then
    echo "Missing dependencies: ${missing_deps[*]}"
    echo "Install with: sudo apt install ${missing_deps[*]}"
    exit 1
fi

# Install systemd user services
echo "Installing systemd user services..."
mkdir -p ~/.config/systemd/user

for service in borgbackup-home borgbackup-shared; do
    cp "$CONFIG_DIR/${service}.service" ~/.config/systemd/user/
    cp "$CONFIG_DIR/${service}.timer" ~/.config/systemd/user/
done

# Reload systemd user services
systemctl --user daemon-reload

# Enable timers
echo "Enabling backup timers..."
systemctl --user enable borgbackup-home.timer
systemctl --user enable borgbackup-shared.timer

# Start timers
systemctl --user start borgbackup-home.timer
systemctl --user start borgbackup-shared.timer

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Next steps:"
echo "1. Set up FTP connection:"
echo "   $SCRIPT_DIR/mount-ftp.sh setup"
echo "   # Edit the credentials file that gets created"
echo ""
echo "2. Test the backup system:"
echo "   $SCRIPT_DIR/borg-backup.sh status"
echo "   $SCRIPT_DIR/borg-backup.sh home    # Test home backup"
echo ""
echo "3. Check timer status:"
echo "   systemctl --user list-timers | grep borgbackup"
echo ""
echo "4. View logs:"
echo "   journalctl --user -u borgbackup-home.service"
echo "   tail -f ~/.local/borgbackup/logs/backup.log"
echo ""
echo "The system will now automatically backup:"
echo "- Home directory: Every hour when in home network"
echo "- Shared partition: Twice daily (8 AM and 8 PM) when in home network"