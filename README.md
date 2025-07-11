# PostgreSQL Near Real-Time Backup & Recovery

A comprehensive PostgreSQL near real-time backup and recovery solution based on pgBackRest, supporting local and remote storage via rclone with complete automatic recovery capabilities.

> **English Documentation** | [中文文档](https://github.com/whispin/postgres_nrt_backup/blob/main/README_ZH.md)

## ✨ Key Features

- 🔄 **Automated Backups**: Scheduled full and incremental backups with intelligent triggers
- 📊 **WAL Growth Monitoring**: Automatic incremental backups triggered by configurable WAL growth thresholds
- ⏰ **Dual Backup Triggers**: Both time-based (cron) and WAL-based incremental backup triggers working in parallel
- 🔍 **Smart WAL Detection**: Intelligent WAL change detection to avoid empty backups and optimize backup efficiency
- 🎯 **Manual Backup Operations**: Support for manually triggered full, incremental, and differential backups
- 🧠 **Smart Backup Logic**: Automatic full backup creation when no base backup exists for incremental backups
- 🔧 **Automatic Recovery**: Complete automated recovery from remote storage to latest backup or specific point-in-time
- 📁 **Separated Storage Structure**: Different backup types stored in organized directory hierarchies
- ☁️ **Multi-Cloud Storage**: Comprehensive cloud storage support via rclone integration (Google Drive, AWS S3, Azure, etc.)
- 📈 **Comprehensive Monitoring**: Real-time backup and recovery monitoring with detailed logging
- 🛡️ **Health Checks & Recovery**: Built-in health checks, failure detection, and automatic recovery mechanisms
- 🔒 **Security**: Support for both RCLONE_CONF_BASE64 environment variable and mounted configuration files

## 🚀 Quick Start

### Backup Mode

```bash
# Pull the latest image
docker pull ghcr.io/whispin/postgres_nrt_backup:latest

# Method 1: Using RCLONE_CONF_BASE64 environment variable (Recommended)
docker run -d \
  --name postgres-backup \
  -p 5432:5432 \
  -e POSTGRES_USER="root" \
  -e POSTGRES_PASSWORD="root123" \
  -e POSTGRES_DB="test_db" \
  -e RCLONE_CONF_BASE64="your_base64_encoded_rclone_config" \
  -e PGBACKREST_STANZA="main" \
  -e WAL_GROWTH_THRESHOLD="1MB" \
  -e INCREMENTAL_BACKUP_SCHEDULE="*/2 * * * *" \
  -e BASE_BACKUP_SCHEDULE="0 3 * * *" \
  ghcr.io/whispin/postgres_nrt_backup:latest

# Method 2: Mounting rclone.conf file
docker run -d \
  --name postgres-backup \
  -p 5432:5432 \
  -e POSTGRES_USER="root" \
  -e POSTGRES_PASSWORD="root123" \
  -e POSTGRES_DB="test_db" \
  -e PGBACKREST_STANZA="main" \
  -e WAL_GROWTH_THRESHOLD="1MB" \
  -e INCREMENTAL_BACKUP_SCHEDULE="*/2 * * * *" \
  -v /path/to/rclone.conf:/root/.config/rclone/rclone.conf:ro \
  ghcr.io/whispin/postgres_nrt_backup:latest
```

### Recovery Mode

```bash
# Method 1: Using RCLONE_CONF_BASE64 environment variable
# Recover to latest backup
docker run -d \
  --name postgres-recovery \
  -p 5432:5432 \
  -e POSTGRES_USER="root" \
  -e POSTGRES_PASSWORD="root123" \
  -e POSTGRES_DB="test_db" \
  -e RCLONE_CONF_BASE64="your_base64_encoded_rclone_config" \
  -e RECOVERY_MODE="true" \
  ghcr.io/whispin/postgres_nrt_backup:latest

# Method 2: Mounting rclone.conf file
# Point-in-time recovery
docker run -d \
  --name postgres-recovery \
  -p 5432:5432 \
  -e POSTGRES_USER="root" \
  -e POSTGRES_PASSWORD="root123" \
  -e POSTGRES_DB="test_db" \
  -e RECOVERY_MODE="true" \
  -e RECOVERY_TARGET_TIME="2025-07-11 14:30:00" \
  -v /path/to/rclone.conf:/root/.config/rclone/rclone.conf:ro \
  ghcr.io/whispin/postgres_nrt_backup:latest
```

### Using Docker Compose

```bash
# Using GHCR image
docker-compose -f docker-compose.ghcr.yml up -d
```

## 🧪 Testing Example

Here's a complete example to test the backup system:

```bash
# 1. Start backup container with test configuration
docker run -d \
  --name postgres-backup-test \
  -p 5432:5432 \
  -e POSTGRES_USER="root" \
  -e POSTGRES_PASSWORD="root123" \
  -e POSTGRES_DB="test_db" \
  -e RCLONE_CONF_BASE64="W2dkcml2ZV0NCnR5cGUgPSBkcml2ZQ0K..." \
  -e WAL_GROWTH_THRESHOLD="1MB" \
  -e INCREMENTAL_BACKUP_SCHEDULE="*/2 * * * *" \
  ghcr.io/whispin/postgres_nrt_backup:latest

# 2. Create test data to trigger WAL growth
docker exec postgres-backup-test psql -U root -d test_db -c "
CREATE TABLE test_table AS
SELECT generate_series(1, 10000) as id,
       'Test data ' || generate_series(1, 10000) as description;
SELECT pg_switch_wal();"

# 3. Check backup status
docker exec postgres-backup-test pgbackrest --stanza=main info

# 4. Monitor logs
docker logs postgres-backup-test --tail 20

# 5. Test recovery
docker run -d \
  --name postgres-recovery-test \
  -p 5433:5432 \
  -e POSTGRES_USER="root" \
  -e POSTGRES_PASSWORD="root123" \
  -e POSTGRES_DB="test_db" \
  -e RCLONE_CONF_BASE64="W2dkcml2ZV0NCnR5cGUgPSBkcml2ZQ0K..." \
  -e RECOVERY_MODE="true" \
  ghcr.io/whispin/postgres_nrt_backup:latest
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
| `POSTGRES_USER` | - | PostgreSQL username (required) |
| `POSTGRES_PASSWORD` | - | PostgreSQL password (required) |
| `POSTGRES_DB` | - | PostgreSQL database name (required) |
| `PGBACKREST_STANZA` | `main` | pgBackRest stanza name |
| `BACKUP_RETENTION_DAYS` | `3` | Backup retention period in days |
| `BASE_BACKUP_SCHEDULE` | `"0 3 * * *"` | Full backup schedule (cron format) |
| `INCREMENTAL_BACKUP_SCHEDULE` | `"0 */6 * * *"` | Incremental backup schedule (cron format) |
| `RCLONE_CONF_BASE64` | - | Base64 encoded rclone configuration (required for cloud storage) |
| `RCLONE_REMOTE_PATH` | `"postgres-backups"` | Remote storage path |
| `RECOVERY_MODE` | `"false"` | Enable recovery mode |
| `WAL_GROWTH_THRESHOLD` | `"100MB"` | WAL growth threshold for automatic incremental backups |
| `WAL_MONITOR_INTERVAL` | `60` | WAL monitoring check interval in seconds |
| `ENABLE_WAL_MONITOR` | `"true"` | Enable WAL growth monitoring |
| `MIN_WAL_GROWTH_FOR_BACKUP` | `"1MB"` | Minimum WAL growth to trigger scheduled incremental backup |

### Recovery Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RECOVERY_MODE` | `"false"` | Enable recovery mode |
| `RECOVERY_TARGET_TIME` | - | Recovery target time (YYYY-MM-DD HH:MM:SS) |
| `RECOVERY_TARGET_NAME` | - | Recovery target name |
| `RECOVERY_TARGET_XID` | - | Recovery target transaction ID |
| `RECOVERY_TARGET_LSN` | - | Recovery target LSN |
| `RECOVERY_TARGET_INCLUSIVE` | `"true"` | Include recovery target |
| `RECOVERY_TARGET_ACTION` | `"promote"` | Action after recovery |

### rclone Configuration (Choose One Method)

#### Method 1: Environment Variable
```bash
# Encode your rclone.conf to base64
RCLONE_CONF_BASE64=$(cat rclone.conf | base64 -w 0)

# Use in docker run
docker run -e RCLONE_CONF_BASE64="$RCLONE_CONF_BASE64" ...
```

#### Method 2: File Mount
```bash
# Mount rclone.conf directly
docker run -v /path/to/rclone.conf:/root/.config/rclone/rclone.conf:ro ...
```

### Volume Mounts

| Path | Description | Permission |
|------|-------------|------------|
| `/var/lib/postgresql/data` | PostgreSQL data directory | Read-only |
| `/backup/local` | Local backup storage | Read-write |
| `/backup/logs` | Backup logs | Read-write |
| `/root/.config/rclone/rclone.conf` | rclone configuration file (optional) | Read-only |

## 🔧 Manual Operations

### Manual Backup Commands

```bash
# Full backup
docker exec postgres-backup /backup/src/bin/backup.sh

# Incremental backup (auto-creates full backup if none exists)
docker exec postgres-backup /backup/src/bin/incremental-backup.sh

# Manual backup with options
docker exec postgres-backup /backup/src/bin/manual-backup.sh --full
docker exec postgres-backup /backup/src/bin/manual-backup.sh --incremental
docker exec postgres-backup /backup/src/bin/manual-backup.sh --diff

# Check backup status
docker exec postgres-backup pgbackrest --stanza=main info

# List available backups
docker exec postgres-backup pgbackrest --stanza=main info --output=json
```

### WAL Monitoring Control

```bash
# Check WAL monitor status
docker exec postgres-backup /backup/src/bin/wal-control.sh status

# View WAL monitor logs
docker exec postgres-backup /backup/src/bin/wal-control.sh logs

# Force incremental backup
docker exec postgres-backup /backup/src/bin/wal-control.sh force-backup

# Restart WAL monitor
docker exec postgres-backup /backup/src/bin/wal-control.sh restart

# Check current WAL growth
docker logs postgres-backup --tail 20
```

### Recovery Control

```bash
# Show recovery configuration
docker exec postgres-recovery /backup/src/bin/recovery-control.sh show-config

# List available backups from remote storage
docker exec postgres-recovery /backup/src/bin/recovery-control.sh list-backups

# Test remote storage connection
docker exec postgres-recovery /backup/src/bin/recovery-control.sh test-connection

# Prepare for recovery
docker exec postgres-recovery /backup/src/bin/recovery-control.sh prepare-recovery
```

## 📁 Backup Directory Structure

The system uses a separated directory structure for different backup types:

```
postgres-backups/
└── {database_name}/
    ├── full-backups/           # Full backup archives
    │   ├── pgbackrest_main_20250711_073855.tar.gz
    │   ├── full_backup_20250711_073855.json
    │   └── ...
    ├── incremental-backups/    # Incremental backup metadata
    │   ├── incremental_backup_20250711_074036.json
    │   ├── wal_incremental_backup_20250711_080000.json
    │   └── ...
    ├── differential-backups/   # Differential backup metadata
    │   ├── differential_backup_20250711_170000.json
    │   └── ...
    └── repository/             # pgBackRest repository (complete backup data)
        ├── archive/            # WAL archive files
        │   └── main/
        │       └── 17-1/
        ├── backup/             # Backup data files
        │   └── main/
        │       ├── 20250711-073641F/          # Full backup
        │       ├── 20250711-073641F_20250711-074028I/  # Incremental backup
        │       └── ...
        └── backup.info         # Backup metadata
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

### ✅ **Backup Features**
- **pgBackRest Integration**: Industry-standard PostgreSQL backup tool with proven reliability
- **Multiple Backup Types**: Full, incremental, and differential backups with intelligent chaining
- **Dual Trigger System**: Time-based (cron) and WAL growth-based automatic backup triggers
- **Smart Backup Logic**: Automatic full backup creation when incremental backups are requested but no base exists
- **WAL Growth Monitoring**: Configurable thresholds (MB/KB units) for automatic incremental backups
- **Empty Backup Prevention**: Intelligent WAL change detection to avoid unnecessary backup operations

### ✅ **Storage & Recovery**
- **Multi-Cloud Support**: Google Drive, AWS S3, Azure Blob, and 40+ cloud providers via rclone
- **Point-in-Time Recovery (PITR)**: Restore to specific timestamps, transaction IDs, or LSNs
- **Automatic Recovery Mode**: Complete automated recovery from remote storage
- **Separated Directory Structure**: Organized storage for different backup types and metadata

### ✅ **Monitoring & Operations**
- **Real-Time Monitoring**: Comprehensive logging and status reporting
- **Health Checks**: Built-in health monitoring and failure detection
- **Manual Operations**: Support for manual backup triggers and administrative commands
- **Flexible Configuration**: Environment variable-based configuration with sensible defaults

## 🔄 CI/CD

The project uses GitHub Actions for automated building and publishing:

- **Triggers**: Push to main branch or PR creation
- **Build Platform**: Ubuntu Latest
- **Publishing Target**: GitHub Container Registry (ghcr.io)
- **Caching**: GitHub Actions cache for optimized build speed


## 🤝 Contributing

Issues and Pull Requests are welcome!

## 📄 License

MIT License
