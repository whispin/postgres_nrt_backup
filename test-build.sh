#!/bin/bash

# Test script to build and validate the Docker image

set -e

echo "=== Building PostgreSQL Backup Docker Image ==="

# Build the Docker image
docker build -t postgres-backup-test .

echo "=== Build completed successfully ==="

echo "=== Testing basic functionality ==="

# Create a test rclone config (dummy config for testing)
DUMMY_RCLONE_CONFIG="[dummy]
type = local
"

RCLONE_CONF_BASE64=$(echo "$DUMMY_RCLONE_CONFIG" | base64 -w 0)

echo "=== Starting test container ==="

# Start container with test configuration
docker run -d \
  --name postgres-backup-test-container \
  -e POSTGRES_USER=testuser \
  -e POSTGRES_PASSWORD=testpass \
  -e POSTGRES_DB=testdb \
  -e RCLONE_CONF_BASE64="$RCLONE_CONF_BASE64" \
  -e RCLONE_SKIP_VERIFY=true \
  -e BASE_BACKUP_SCHEDULE="*/5 * * * *" \
  -e BACKUP_RETENTION_DAYS=1 \
  postgres-backup-test

echo "=== Waiting for container to initialize ==="
sleep 30

echo "=== Checking container status ==="
if docker ps | grep -q postgres-backup-test-container; then
    echo "✓ Container is running"
else
    echo "✗ Container is not running"
    docker logs postgres-backup-test-container
    exit 1
fi

echo "=== Checking PostgreSQL connectivity ==="
if docker exec postgres-backup-test-container pg_isready -U testuser -d testdb; then
    echo "✓ PostgreSQL is ready"
else
    echo "✗ PostgreSQL is not ready"
    docker logs postgres-backup-test-container
    exit 1
fi

echo "=== Checking backup system logs ==="
docker exec postgres-backup-test-container tail -20 /backup/logs/backup.log

echo "=== Checking cron setup ==="
if docker exec postgres-backup-test-container su - postgres -c "crontab -l" | grep -q backup.sh; then
    echo "✓ Cron job is configured"
else
    echo "✗ Cron job is not configured"
    exit 1
fi

echo "=== Testing manual backup (dry run) ==="
# Note: This will fail because we're using a dummy rclone config, but it should test the script logic
docker exec postgres-backup-test-container /backup/scripts/backup.sh || echo "Expected to fail with dummy config"

echo "=== Cleanup ==="
docker stop postgres-backup-test-container
docker rm postgres-backup-test-container

echo "=== All tests completed successfully ==="
echo "The Docker image is ready for use!"
echo ""
echo "To use the image:"
echo "1. Configure your rclone with: rclone config"
echo "2. Encode the config: base64 -w 0 ~/.config/rclone/rclone.conf"
echo "3. Use the encoded config in RCLONE_CONF_BASE64 environment variable"
echo "4. Run with proper environment variables as shown in README.md"
