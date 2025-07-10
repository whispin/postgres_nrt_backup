# Quick Start Guide

## 🚀 Getting Started in 5 Minutes

### Prerequisites

- Docker installed and running
- PostgreSQL database to backup
- rclone configuration for remote storage (optional)

### Step 1: Prepare rclone Configuration (Choose One Method)

#### Method 1: Environment Variable (Recommended for Production)

```bash
# Create rclone config file
cat > rclone.conf << EOF
[s3-remote]
type = s3
provider = AWS
access_key_id = your_access_key
secret_access_key = your_secret_key
region = us-east-1
EOF

# Encode to base64
RCLONE_CONF_BASE64=$(cat rclone.conf | base64 -w 0)
echo $RCLONE_CONF_BASE64
```

#### Method 2: File Mount (Recommended for Development)

```bash
# Create rclone config file
cat > /path/to/rclone.conf << EOF
[s3-remote]
type = s3
provider = AWS
access_key_id = your_access_key
secret_access_key = your_secret_key
region = us-east-1
EOF
```

### Step 2: Run Backup Container

#### Using Method 1 (Environment Variable):
```bash
docker run -d \
  --name postgres-backup \
  -e POSTGRES_USER=myuser \
  -e POSTGRES_PASSWORD=mypassword \
  -e POSTGRES_DB=mydatabase \
  -e RCLONE_CONF_BASE64="$RCLONE_CONF_BASE64" \
  -e PGBACKREST_STANZA=main \
  -e WAL_GROWTH_THRESHOLD="100MB" \
  -v /var/lib/postgresql/data:/var/lib/postgresql/data:ro \
  -v ./backup-logs:/backup/logs \
  ghcr.io/whispin/postgres_nrt_backup:latest
```

#### Using Method 2 (File Mount):
```bash
docker run -d \
  --name postgres-backup \
  -e POSTGRES_USER=myuser \
  -e POSTGRES_PASSWORD=mypassword \
  -e POSTGRES_DB=mydatabase \
  -e PGBACKREST_STANZA=main \
  -e WAL_GROWTH_THRESHOLD="100MB" \
  -v /var/lib/postgresql/data:/var/lib/postgresql/data:ro \
  -v ./backup-logs:/backup/logs \
  -v /path/to/rclone.conf:/root/.config/rclone/rclone.conf:ro \
  ghcr.io/whispin/postgres_nrt_backup:latest
```

### Step 3: Verify Backup System

```bash
# Check container status
docker ps | grep postgres-backup

# Check logs
docker logs postgres-backup

# Verify backup configuration
docker exec postgres-backup /backup/scripts/manual-backup.sh --check
```

### Step 4: Perform Manual Backup

```bash
# Full backup
docker exec postgres-backup /backup/scripts/manual-backup.sh --full

# Check backup status
docker exec postgres-backup /backup/scripts/manual-backup.sh --list
```

### Step 5: Monitor WAL Growth

```bash
# Check WAL monitor status
docker exec postgres-backup /backup/scripts/wal-control.sh status

# View WAL monitor logs
docker exec postgres-backup /backup/scripts/wal-control.sh logs -n 20
```

## 🔄 Recovery Example

### Recover to Latest Backup

```bash
docker run -d \
  --name postgres-recovery \
  -e POSTGRES_USER=myuser \
  -e POSTGRES_PASSWORD=mypassword \
  -e POSTGRES_DB=mydatabase \
  -e RCLONE_CONF_BASE64="$RCLONE_CONF_BASE64" \
  -e RECOVERY_MODE="true" \
  -v ./recovery-data:/var/lib/postgresql/data \
  ghcr.io/whispin/postgres_nrt_backup:latest
```

### Point-in-Time Recovery

```bash
docker run -d \
  --name postgres-recovery \
  -e POSTGRES_USER=myuser \
  -e POSTGRES_PASSWORD=mypassword \
  -e POSTGRES_DB=mydatabase \
  -e RCLONE_CONF_BASE64="$RCLONE_CONF_BASE64" \
  -e RECOVERY_MODE="true" \
  -e RECOVERY_TARGET_TIME="2025-07-10 14:30:00" \
  -v ./recovery-data:/var/lib/postgresql/data \
  ghcr.io/whispin/postgres_nrt_backup:latest
```

## 📊 Monitoring

### Check Backup Status

```bash
# View backup logs
docker exec postgres-backup tail -f /backup/logs/backup.log

# Check WAL monitor
docker exec postgres-backup /backup/scripts/wal-control.sh status

# List all backups
docker exec postgres-backup /backup/scripts/manual-backup.sh --list
```

### Health Check

```bash
# Run health check
docker exec postgres-backup /backup/scripts/healthcheck.sh

# Check container health
docker inspect postgres-backup | grep Health -A 10
```

## 🛠️ Troubleshooting

### Common Issues

1. **Container fails to start**
   ```bash
   # Check logs
   docker logs postgres-backup
   
   # Check environment variables
   docker exec postgres-backup env | grep POSTGRES
   ```

2. **Backup fails**
   ```bash
   # Check backup logs
   docker exec postgres-backup cat /backup/logs/backup.log
   
   # Test PostgreSQL connection
   docker exec postgres-backup pg_isready -U $POSTGRES_USER -d $POSTGRES_DB
   ```

3. **Remote storage issues**
   ```bash
   # Test rclone configuration
   docker exec postgres-backup rclone config show
   
   # Test remote connection
   docker exec postgres-backup /backup/scripts/recovery-control.sh test-connection
   ```

### Debug Mode

```bash
# Run with debug logging
docker run -d \
  --name postgres-backup \
  -e DEBUG="true" \
  -e POSTGRES_USER=myuser \
  # ... other environment variables
  ghcr.io/whispin/postgres_nrt_backup:latest
```

## 📚 Next Steps

- Read the [Manual Backup Guide](MANUAL_BACKUP_GUIDE.md)
- Learn about [WAL Monitoring](WAL_MONITOR_GUIDE.md)
- Explore [Recovery Options](RECOVERY_GUIDE.md)
- Understand [Smart Backup Logic](SMART_BACKUP_LOGIC.md)

## 💡 Tips

1. **Set appropriate WAL threshold**: Start with 100MB and adjust based on your database activity
2. **Monitor backup logs**: Regularly check logs for any issues
3. **Test recovery**: Periodically test your backup recovery process
4. **Use health checks**: Enable Docker health checks for monitoring
5. **Backup retention**: Adjust retention days based on your requirements

That's it! Your PostgreSQL backup system is now running with automatic WAL monitoring and remote storage support.
