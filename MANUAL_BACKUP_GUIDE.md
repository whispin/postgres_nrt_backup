# 手动备份操作指南

## 概述

现在你可以在容器内手动触发PostgreSQL备份操作。我们提供了一个专门的脚本 `manual-backup.sh` 来执行各种类型的备份。

## 使用方法

### 基本语法

```bash
docker exec <container_name> /backup/scripts/manual-backup.sh [OPTIONS]
```

### 可用选项

| 选项 | 长选项 | 描述 |
|------|--------|------|
| `-h` | `--help` | 显示帮助信息 |
| `-f` | `--full` | 执行完整备份（默认） |
| `-i` | `--incremental` | 执行增量备份 |
| `-d` | `--diff` | 执行差异备份 |
| `-c` | `--check` | 检查备份状态和配置 |
| `-l` | `--list` | 列出可用的备份 |
| `-v` | `--verbose` | 启用详细输出 |

## 实际使用示例

假设你的容器名称是 `postgres-backup-container`：

### 1. 执行完整备份

```bash
# 方法1：使用默认设置
docker exec postgres-backup-container /backup/scripts/manual-backup.sh

# 方法2：明确指定完整备份
docker exec postgres-backup-container /backup/scripts/manual-backup.sh --full

# 方法3：带详细输出的完整备份
docker exec postgres-backup-container /backup/scripts/manual-backup.sh --full --verbose
```

### 2. 执行增量备份

```bash
docker exec postgres-backup-container /backup/scripts/manual-backup.sh --incremental
```

### 3. 执行差异备份

```bash
docker exec postgres-backup-container /backup/scripts/manual-backup.sh --diff
```

### 4. 检查备份配置

```bash
docker exec postgres-backup-container /backup/scripts/manual-backup.sh --check
```

### 5. 列出可用备份

```bash
docker exec postgres-backup-container /backup/scripts/manual-backup.sh --list
```

### 6. 查看帮助信息

```bash
docker exec postgres-backup-container /backup/scripts/manual-backup.sh --help
```

## 备份类型说明

### 完整备份 (Full Backup)
- **用途**: 创建数据库的完整副本
- **特点**: 包含所有数据，可以独立恢复
- **建议**: 定期执行，作为其他备份类型的基础

### 增量备份 (Incremental Backup)
- **用途**: 只备份自上次备份以来的更改
- **特点**: 备份速度快，占用空间小
- **要求**: 需要有完整备份作为基础
- **智能检查**: 如果没有全量备份，会自动先执行一次全量备份

### 差异备份 (Differential Backup)
- **用途**: 备份自上次完整备份以来的所有更改
- **特点**: 比增量备份大，但恢复更简单
- **要求**: 需要有完整备份作为基础
- **智能检查**: 如果没有全量备份，会自动先执行一次全量备份

## 监控和日志

### 查看备份日志

```bash
# 查看实时日志
docker exec postgres-backup-container tail -f /backup/logs/backup.log

# 查看最近的日志
docker exec postgres-backup-container tail -50 /backup/logs/backup.log

# 搜索特定内容
docker exec postgres-backup-container grep "ERROR\|WARN" /backup/logs/backup.log
```

### 检查容器状态

```bash
# 检查容器是否运行
docker ps | grep postgres-backup

# 查看容器日志
docker logs postgres-backup-container

# 检查健康状态
docker exec postgres-backup-container /backup/scripts/healthcheck.sh
```

## 故障排除

### 常见问题

1. **权限错误**
   ```bash
   # 检查文件权限
   docker exec postgres-backup-container ls -la /backup/scripts/
   ```

2. **PostgreSQL连接失败**
   ```bash
   # 检查PostgreSQL状态
   docker exec postgres-backup-container pg_isready -U $POSTGRES_USER -d $POSTGRES_DB
   ```

3. **rclone配置问题**
   ```bash
   # 检查rclone配置
   docker exec postgres-backup-container rclone config show
   ```

### 调试模式

启用详细输出来调试问题：

```bash
docker exec postgres-backup-container /backup/scripts/manual-backup.sh --full --verbose
```

## 最佳实践

1. **定期完整备份**: 每周至少执行一次完整备份
2. **增量备份**: 在完整备份之间执行增量备份
3. **验证备份**: 定期检查备份的完整性
4. **监控日志**: 定期查看备份日志确保没有错误
5. **测试恢复**: 定期测试备份恢复过程

## 自动化示例

你也可以创建脚本来自动化备份操作：

```bash
#!/bin/bash
# backup-automation.sh

CONTAINER_NAME="postgres-backup-container"

# 每日增量备份
docker exec $CONTAINER_NAME /backup/scripts/manual-backup.sh --incremental

# 检查备份状态
if [ $? -eq 0 ]; then
    echo "备份成功完成"
else
    echo "备份失败，请检查日志"
    docker exec $CONTAINER_NAME tail -20 /backup/logs/backup.log
fi
```

## 注意事项

1. 确保容器有足够的磁盘空间
2. 备份过程中避免对数据库进行大量写操作
3. 定期清理旧的备份文件以节省空间
4. 确保rclone配置正确以便远程存储
