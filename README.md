# PostgreSQL Near Real-Time Backup & Recovery

A comprehensive PostgreSQL near real-time backup and recovery solution based on pgBackRest, supporting local and remote storage via rclone with complete automatic recovery capabilities.

> **English Documentation** | [中文文档](https://github.com/whispin/postgres_nrt_backup/blob/main/README_ZH.md)

## ✨ Key Features

- 🔄 **Automated Backups**: Scheduled full and incremental backups
- 📊 **WAL Monitoring**: Automatic incremental backups triggered by WAL growth
- 🎯 **Manual Backups**: Support for manually triggered backup operations
- 🧠 **Smart Backup Logic**: Automatic full backup creation when incremental backups are requested
- 🔧 **Automatic Recovery**: Automated recovery from remote storage to specific point-in-time
- 📁 **Separated Storage**: Different backup types stored in independent directories
- ☁️ **Cloud Storage**: Multi-cloud support via rclone integration
- 📈 **Monitoring & Logging**: Comprehensive backup and recovery monitoring
- 🛡️ **Health Checks**: Built-in health checks and failure recovery

## 🚀 Quick Start

### Backup Mode

```bash
# Pull the latest image
docker pull ghcr.io/whispin/postgres_nrt_backup:latest

# Run backup container
docker run -d \
  --name postgres-backup \
  -e POSTGRES_USER=myuser \
  -e POSTGRES_PASSWORD=mypass \
  -e POSTGRES_DB=mydb \
  -e RCLONE_CONF_BASE64="your_base64_config" \
  -e PGBACKREST_STANZA=main \
  -e WAL_GROWTH_THRESHOLD="100MB" \
  -v /path/to/postgres/data:/var/lib/postgresql/data:ro \
  -v /path/to/backup:/backup/local \
  ghcr.io/whispin/postgres_nrt_backup:latest
```

### Recovery Mode

```bash
# Recover to latest backup
docker run -d \
  --name postgres-recovery \
  -e POSTGRES_USER=myuser \
  -e POSTGRES_PASSWORD=mypass \
  -e POSTGRES_DB=mydb \
  -e RCLONE_CONF_BASE64="your_base64_config" \
  -e RECOVERY_MODE="true" \
  ghcr.io/whispin/postgres_nrt_backup:latest

# Point-in-time recovery
docker run -d \
  --name postgres-recovery \
  -e RECOVERY_MODE="true" \
  -e RECOVERY_TARGET_TIME="2025-07-10 14:30:00" \
  # ... other environment variables
  ghcr.io/whispin/postgres_nrt_backup:latest
```

### Using Docker Compose

```bash
# Using GHCR image
docker-compose -f docker-compose.ghcr.yml up -d
```

## 📦 Image Information

### Available Tags
- `latest` - Latest stable version
- `main-<sha>` - Specific commit version
- `pr-<number>` - PR build version (testing only)

### Image Size Optimization
- Multi-stage build process
- Separated build and runtime environments
- Runtime-only dependencies
- Proper shared library installation (`*-libs` packages)
- Estimated size reduction: 150-300MB

## ⚙️ Configuration Options

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `POSTGRES_USER` | - | PostgreSQL username |
| `POSTGRES_PASSWORD` | - | PostgreSQL password |
| `POSTGRES_DB` | - | PostgreSQL database name |
| `PGBACKREST_STANZA` | `main` | pgBackRest stanza name |
| `BACKUP_RETENTION_DAYS` | `3` | Backup retention period in days |
| `BASE_BACKUP_SCHEDULE` | `"0 3 * * *"` | Full backup schedule (cron format) |
| `RCLONE_CONF_BASE64` | - | Base64 encoded rclone configuration |
| `RCLONE_REMOTE_PATH` | `"postgres-backups"` | Remote storage path |
| `RECOVERY_MODE` | `"false"` | Enable recovery mode |
| `WAL_GROWTH_THRESHOLD` | `"100MB"` | WAL growth threshold for auto backups |
| `WAL_MONITOR_INTERVAL` | `60` | WAL monitoring interval in seconds |
| `ENABLE_WAL_MONITOR` | `"true"` | Enable WAL monitoring |

### Recovery Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RECOVERY_TARGET_TIME` | - | Recovery target time (YYYY-MM-DD HH:MM:SS) |
| `RECOVERY_TARGET_NAME` | - | Recovery target name |
| `RECOVERY_TARGET_XID` | - | Recovery target transaction ID |
| `RECOVERY_TARGET_LSN` | - | Recovery target LSN |
| `RECOVERY_TARGET_INCLUSIVE` | `"true"` | Include recovery target |
| `RECOVERY_TARGET_ACTION` | `"promote"` | Action after recovery |

### Volume Mounts

| Path | Description | Permission |
|------|-------------|------------|
| `/var/lib/postgresql/data` | PostgreSQL data directory | Read-only |
| `/backup/local` | Local backup storage | Read-write |
| `/backup/logs` | Backup logs | Read-write |
| `/root/.config/rclone/rclone.conf` | rclone configuration file | Read-only |

## 🔧 Manual Operations

### Manual Backup Commands

```bash
# Full backup
docker exec postgres-backup /backup/scripts/manual-backup.sh --full

# Incremental backup (auto-creates full backup if none exists)
docker exec postgres-backup /backup/scripts/manual-backup.sh --incremental

# Differential backup
docker exec postgres-backup /backup/scripts/manual-backup.sh --diff

# Check backup configuration
docker exec postgres-backup /backup/scripts/manual-backup.sh --check

# List available backups
docker exec postgres-backup /backup/scripts/manual-backup.sh --list
```

### WAL Monitoring Control

```bash
# Check WAL monitor status
docker exec postgres-backup /backup/scripts/wal-control.sh status

# View WAL monitor logs
docker exec postgres-backup /backup/scripts/wal-control.sh logs --follow

# Force incremental backup
docker exec postgres-backup /backup/scripts/wal-control.sh force-backup

# Restart WAL monitor
docker exec postgres-backup /backup/scripts/wal-control.sh restart
```

### Recovery Control

```bash
# Show recovery configuration
docker exec postgres-recovery /backup/scripts/recovery-control.sh show-config

# List available backups from remote storage
docker exec postgres-recovery /backup/scripts/recovery-control.sh list-backups

# Test remote storage connection
docker exec postgres-recovery /backup/scripts/recovery-control.sh test-connection

# Prepare for recovery
docker exec postgres-recovery /backup/scripts/recovery-control.sh prepare-recovery
```

## 📁 Backup Directory Structure

The system uses a separated directory structure for different backup types:

```
postgres-backups/
└── {database_identifier}/
    ├── full-backups/           # Full backups
    │   ├── pgbackrest_main_20250710_143000.tar.gz
    │   ├── full_backup_20250710_143000.json
    │   └── ...
    ├── incremental-backups/    # Incremental backups
    │   ├── incremental_backup_20250710_150000.json
    │   ├── wal_incremental_backup_20250710_153000.json
    │   └── ...
    ├── differential-backups/   # Differential backups
    │   ├── differential_backup_20250710_170000.json
    │   └── ...
    └── repository/             # pgBackRest repository
        ├── archive/
        ├── backup/
        └── ...
```

## 🔧 Building and Development

### Local Build

```bash
# Build optimized image
docker build -t postgres-backup:local .

# Compare image sizes
./compare-image-sizes.sh
```

### Development Environment

```bash
# Clone repository
git clone https://github.com/whispin/postgres_nrt_backup.git
cd postgres_nrt_backup

# Build and test
./test-build.sh
```

## 📋 Feature Highlights

- ✅ Reliable backups based on pgBackRest
- ✅ Support for incremental and differential backups
- ✅ Automated backup scheduling (cron)
- ✅ Remote storage support (rclone)
- ✅ Health checks and monitoring
- ✅ Flexible configuration options
- ✅ Optimized Docker image size
- ✅ Smart backup logic with automatic full backup creation
- ✅ Point-in-time recovery (PITR)
- ✅ WAL-based automatic incremental backups
- ✅ Separated backup directory structure

## 🔄 CI/CD

The project uses GitHub Actions for automated building and publishing:

- **Triggers**: Push to main branch or PR creation
- **Build Platform**: Ubuntu Latest
- **Publishing Target**: GitHub Container Registry (ghcr.io)
- **Caching**: GitHub Actions cache for optimized build speed

## 📚 Documentation

- [Quick Start Guide](QUICK_START_EN.md) - Get started in 5 minutes
- [Manual Backup Guide](MANUAL_BACKUP_GUIDE.md)
- [WAL Monitor Guide](WAL_MONITOR_GUIDE.md)
- [Recovery Guide](RECOVERY_GUIDE.md)

## 🤝 Contributing

Issues and Pull Requests are welcome!

## 📄 License

MIT License
