# BorgBackup Time Machine

A Time Machine-like backup system for Linux using BorgBackup with automatic scheduling, FTP sync, and network-aware operation.

## Features

- **Automatic Scheduling**: Hourly home backups, 3x daily shared partition backups
- **Network-Aware**: Only runs when in home network (saves mobile data & battery)
- **FTP Support**: Uses lftp for reliable FTP access instead of problematic SMB
- **Encrypted Backups**: All backups are encrypted with BorgBackup's encryption
- **No Queue Buildup**: Prevents overlapping backups with lock files
- **Time Machine Retention**: Smart pruning (hourly, daily, weekly, monthly, yearly)
- **systemd Integration**: Modern timer-based scheduling with persistent flags

## Requirements

- **Ubuntu/Debian Linux** (tested on Ubuntu 24.04)
- **borgbackup** - Backup software
- **lftp** - FTP client for syncing
- **systemd** - Timer management (user services)
- **FTP-enabled router/NAS** - For backup storage

Install dependencies:
```bash
sudo apt install borgbackup lftp
```

## Quick Start

1. **Clone and install**:
   ```bash
   git clone https://github.com/svendoering/borgbackup-timemachine.git
   cd borgbackup-timemachine
   ./scripts/install-backup-system.sh
   ```

2. **Configure FTP**:
   ```bash
   ./scripts/mount-ftp.sh setup
   # Edit the credentials file that gets created
   ```

3. **Test the system**:
   ```bash
   ./scripts/backup-manager.sh status
   ./scripts/backup-manager.sh backup home
   ```

## Configuration

### Basic Setup

1. **Edit `config/backup.conf`**:
   - Set your FTP host, username
   - Configure network gateway and WiFi SSID
   - Adjust backup paths if needed

2. **Create FTP credentials**:
   ```bash
   echo "user=your_ftp_username" > ~/.local/borgbackup/config/ftp-credentials
   echo "pass=your_ftp_password" >> ~/.local/borgbackup/config/ftp-credentials
   chmod 600 ~/.local/borgbackup/config/ftp-credentials
   ```

3. **Set Borg passphrase**:
   ```bash
   echo "your_borg_passphrase" > ~/.borg_passphrase
   chmod 600 ~/.borg_passphrase
   ```

### Backup Schedule

- **Home Directory**: Every hour when laptop is running and in home network
- **Shared Partition**: 10:00, 18:00, 21:00 when in home network

### Retention Policy (Time Machine-like)

- **Hourly**: 24 backups (1 day)
- **Daily**: 7 backups (1 week)
- **Weekly**: 4 backups (1 month)
- **Monthly**: 6 backups (6 months)
- **Yearly**: 2 backups (2 years)

## Architecture

### Version 2.0: Separated FTP Upload System

Starting with version 2.0, the backup system uses a **decoupled approach** that solves sleep/suspend mode issues:

#### Backup Process:
1. **Sync Down**: Download repository from FTP to local storage
2. **Backup**: BorgBackup operates on local repository copy  
3. **Local Storage**: Backup is immediately available locally

#### FTP Upload Process (Separate Timer):
1. **Independent Upload**: Separate timer checks for repository changes
2. **Smart Upload**: Only uploads when changes detected and system is active
3. **Power-Aware**: Only runs when on AC power to preserve battery
4. **Sleep-Resistant**: Runs every 15 minutes when system is awake

This approach prevents FTP upload failures when the laptop goes to sleep mid-backup and significantly improves battery life.

## Directory Structure

```
~/.local/borgbackup/
├── scripts/                  # Backup logic
│   ├── backup-manager.sh     # Central management
│   ├── borg-backup.sh        # Main backup script
│   ├── ftp-upload.sh         # Separate FTP upload (v2.0+)
│   ├── mount-ftp.sh          # FTP sync operations
│   ├── network-check.sh      # Network detection
│   └── install-backup-system.sh # Installation
├── config/
│   ├── backup.conf           # Main configuration
│   ├── ftp-credentials       # FTP login (create manually)
│   └── *.service, *.timer    # systemd service files
├── logs/
│   └── *.log                 # Backup activity logs
└── mounts/backup/            # Local repository mirrors
    ├── user-data-repo/       # Home directory backups
    └── shared-data-repo/     # Shared partition backups
```

## Usage

### Management Commands

```bash
# Central management script
./scripts/backup-manager.sh COMMAND

# Available commands:
status                    # Show system status
backup {home|shared}      # Force backup
ftp {setup|test|check}    # Manage FTP connection
ftp-status               # Show detailed FTP upload status (v2.0+)
timers {enable|disable}   # Control automatic scheduling
logs {backup|home|shared} # View backup logs
list {home|shared}        # List available archives
```

### Monitoring

```bash
# Check system status
./scripts/backup-manager.sh status

# View logs
tail -f ~/.local/borgbackup/logs/backup.log

# Check systemd timers (includes FTP upload timer in v2.0+)
systemctl --user list-timers | grep -E "(borgbackup|ftp-upload)"

# View systemd logs
journalctl --user -u borgbackup-home.service -f
```

## Troubleshooting

### FTP Issues
```bash
# Test FTP connection
./scripts/mount-ftp.sh test

# Check FTP status
./scripts/mount-ftp.sh check

# Check FTP upload status (v2.0+)
./scripts/backup-manager.sh ftp-status

# Force FTP upload (v2.0+)
./scripts/ftp-upload.sh force user-data-repo
./scripts/ftp-upload.sh force shared-data-repo
```

### Network Detection
```bash
# Test network detection
./scripts/network-check.sh home
./scripts/network-check.sh status
```

### Backup Problems
```bash
# Remove stale lock files
rm -f /tmp/borgbackup-*.lock

# Force backup
./scripts/backup-manager.sh backup home
```

## Security

- All backups are encrypted using BorgBackup's repokey-blake2 encryption
- FTP credentials stored in protected file (mode 600)
- Network detection prevents backups outside trusted network
- Repository keys backed up separately (recommended)

## Future Plans

- Hetzner Storage Box integration for offsite backups
- Email notifications for backup failures
- Web dashboard for backup monitoring

## Contributing

Pull requests welcome! Please ensure:
- Code follows existing style
- Security best practices maintained
- Documentation updated

## License

MIT License - see LICENSE file for details

## Responsible AI Development

This project was developed with significant assistance from **Claude Code** (Anthropic's CLI), but – and this is important – every single line of code has been manually reviewed, tested, and validated by an actual human (that would be me! 👋).

While Claude helped with the heavy lifting, architecture decisions, and even some of the more tedious configuration templating, I've personally:
- ✅ **Tested the entire system** on my own laptop for weeks
- ✅ **Code-reviewed every script** for security and functionality  
- ✅ **Verified all configurations** work in real-world scenarios
- ✅ **Sanitized sensitive information** before making it public
- ✅ **Run actual backups** and recovery tests

Think of Claude as a very capable coding partner who never gets tired of writing boilerplate, but the final responsibility (and the backup of my precious development projects!) rests firmly with human judgment. 

The AI helped me build it faster and probably caught some edge cases I might have missed, but I wouldn't trust my data to anything I haven't personally verified. Neither should you! 😉

## Blog Article

This backup system is detailed in a comprehensive blog post at [moorwald.dev](https://moorwald.dev) including technical deep-dive, lessons learned, and implementation decisions.