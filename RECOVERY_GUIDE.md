# PostgreSQL自动恢复功能指南

## 概述

PostgreSQL自动恢复功能可以从配置的rclone远程存储自动拉取备份数据并进行恢复。支持恢复到最新备份或指定的时间点。

## 功能特性

- ✅ 自动从远程存储下载备份仓库
- ✅ 支持恢复到最新备份
- ✅ 支持时间点恢复（PITR）
- ✅ 支持多种恢复目标（时间、LSN、XID、命名点）
- ✅ 自动配置恢复参数
- ✅ 完整的恢复监控和日志
- ✅ 恢复后自动启动正常服务

## 环境变量配置

### 基本恢复配置

| 变量名 | 默认值 | 描述 |
|--------|--------|------|
| `RECOVERY_MODE` | `false` | 启用恢复模式 |
| `RECOVERY_TARGET_INCLUSIVE` | `true` | 是否包含恢复目标 |
| `RECOVERY_TARGET_ACTION` | `promote` | 恢复后动作 |

### 恢复目标配置（选择其一）

| 变量名 | 格式 | 描述 |
|--------|------|------|
| `RECOVERY_TARGET_TIME` | `YYYY-MM-DD HH:MM:SS` | 恢复到指定时间 |
| `RECOVERY_TARGET_NAME` | `string` | 恢复到命名还原点 |
| `RECOVERY_TARGET_XID` | `number` | 恢复到指定事务ID |
| `RECOVERY_TARGET_LSN` | `0/1234567` | 恢复到指定LSN |

### 恢复后动作选项

| 动作 | 描述 |
|------|------|
| `promote` | 恢复后提升为主库（默认） |
| `pause` | 恢复后暂停，等待手动提升 |
| `shutdown` | 恢复后关闭数据库 |

## 使用示例

### 1. 恢复到最新备份

```bash
docker run -d --name postgres-recovery \
    -e POSTGRES_USER=myuser \
    -e POSTGRES_PASSWORD=mypass \
    -e POSTGRES_DB=mydb \
    -e RCLONE_CONF_BASE64="your_base64_config" \
    -e PGBACKREST_STANZA=main \
    -e RECOVERY_MODE="true" \
    your-postgres-backup-image
```

### 2. 时间点恢复

```bash
docker run -d --name postgres-recovery \
    -e POSTGRES_USER=myuser \
    -e POSTGRES_PASSWORD=mypass \
    -e POSTGRES_DB=mydb \
    -e RCLONE_CONF_BASE64="your_base64_config" \
    -e PGBACKREST_STANZA=main \
    -e RECOVERY_MODE="true" \
    -e RECOVERY_TARGET_TIME="2025-07-10 14:30:00" \
    your-postgres-backup-image
```

### 3. 恢复到指定LSN

```bash
docker run -d --name postgres-recovery \
    -e RECOVERY_MODE="true" \
    -e RECOVERY_TARGET_LSN="0/3A000028" \
    -e RECOVERY_TARGET_INCLUSIVE="false" \
    # ... 其他环境变量
    your-postgres-backup-image
```

### 4. 恢复到命名还原点

```bash
docker run -d --name postgres-recovery \
    -e RECOVERY_MODE="true" \
    -e RECOVERY_TARGET_NAME="before_migration" \
    # ... 其他环境变量
    your-postgres-backup-image
```

## 恢复流程

### 1. 自动恢复流程

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   启动容器      │───▶│   检测恢复模式    │───▶│   验证参数      │
│ RECOVERY_MODE   │    │                  │    │                 │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                                │
                                ▼
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   启动PostgreSQL │◀───│   配置恢复参数    │◀───│   执行恢复      │
│   正常服务      │    │                  │    │                 │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                                ▲
                                │
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   下载备份仓库   │───▶│   准备数据目录    │───▶│   执行pgBackRest │
│   从远程存储    │    │                  │    │   restore       │
└─────────────────┘    └──────────────────┘    └─────────────────┘
```

### 2. 恢复步骤详解

1. **参数验证**: 检查恢复目标参数的有效性
2. **下载仓库**: 从远程存储下载完整的备份仓库
3. **准备目录**: 备份现有数据目录，创建新的数据目录
4. **执行恢复**: 使用pgBackRest执行数据恢复
5. **配置恢复**: 创建recovery.signal和恢复配置
6. **启动数据库**: 启动PostgreSQL进行恢复
7. **监控进度**: 监控恢复进度直到完成

## 恢复控制和监控

### 基本命令

```bash
# 检查恢复配置
docker exec postgres-recovery /backup/scripts/recovery-control.sh show-config

# 列出可用备份
docker exec postgres-recovery /backup/scripts/recovery-control.sh list-backups

# 查看恢复日志
docker exec postgres-recovery /backup/scripts/recovery-control.sh logs

# 测试远程连接
docker exec postgres-recovery /backup/scripts/recovery-control.sh test-connection
```

### 恢复前准备

```bash
# 验证恢复目标
docker exec postgres-recovery /backup/scripts/recovery-control.sh validate-target

# 准备恢复（下载仓库、验证配置）
docker exec postgres-recovery /backup/scripts/recovery-control.sh prepare-recovery
```

### 监控恢复进度

```bash
# 实时查看恢复日志
docker exec postgres-recovery /backup/scripts/recovery-control.sh logs --follow

# 查看PostgreSQL日志
docker logs postgres-recovery

# 检查恢复状态
docker exec postgres-recovery psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();
"
```

## 高级用法

### 1. 分步恢复

```bash
# 第一步：只下载备份仓库
docker run --rm \
    -e RCLONE_CONF_BASE64="your_config" \
    -v ./backup-repo:/var/lib/pgbackrest \
    your-postgres-backup-image \
    /backup/scripts/recovery-control.sh download-repo

# 第二步：使用本地仓库进行恢复
docker run -d \
    -e RECOVERY_MODE="true" \
    -e RECOVERY_TARGET_TIME="2025-07-10 14:30:00" \
    -v ./backup-repo:/var/lib/pgbackrest \
    your-postgres-backup-image
```

### 2. 恢复验证

```bash
# 恢复完成后验证数据
docker exec postgres-recovery psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
-- 检查表数量
SELECT schemaname, tablename FROM pg_tables WHERE schemaname = 'public';

-- 检查数据量
SELECT 'table_name', COUNT(*) FROM your_table;

-- 检查最后更新时间
SELECT MAX(updated_at) FROM your_table WHERE updated_at IS NOT NULL;
"
```

### 3. 恢复后配置

```bash
# 恢复完成后，可能需要：
# 1. 更新统计信息
docker exec postgres-recovery psql -U $POSTGRES_USER -d $POSTGRES_DB -c "ANALYZE;"

# 2. 重建索引（如果需要）
docker exec postgres-recovery psql -U $POSTGRES_USER -d $POSTGRES_DB -c "REINDEX DATABASE $POSTGRES_DB;"

# 3. 检查数据库一致性
docker exec postgres-recovery psql -U $POSTGRES_USER -d $POSTGRES_DB -c "SELECT pg_database_size(current_database());"
```

## 故障排除

### 常见问题

1. **远程存储连接失败**
   ```bash
   # 测试rclone配置
   docker exec postgres-recovery rclone config show
   docker exec postgres-recovery /backup/scripts/recovery-control.sh test-connection
   ```

2. **备份仓库不存在**
   ```bash
   # 检查远程路径
   docker exec postgres-recovery rclone lsd remote:postgres-backups/
   ```

3. **恢复目标时间无效**
   ```bash
   # 验证时间格式
   docker exec postgres-recovery /backup/scripts/recovery-control.sh validate-target
   ```

4. **恢复进程卡住**
   ```bash
   # 检查PostgreSQL进程
   docker exec postgres-recovery ps aux | grep postgres
   
   # 检查恢复状态
   docker exec postgres-recovery psql -c "SELECT pg_is_in_recovery();"
   ```

### 调试模式

```bash
# 启用详细日志
docker run -d \
    -e RECOVERY_MODE="true" \
    -e DEBUG="true" \
    your-postgres-backup-image

# 查看详细恢复日志
docker exec postgres-recovery /backup/scripts/recovery-control.sh logs -n 100
```

## 最佳实践

1. **恢复前准备**
   - 确认备份的完整性和可用性
   - 验证恢复目标时间的合理性
   - 准备足够的磁盘空间

2. **恢复过程**
   - 监控恢复进度和日志
   - 确保网络连接稳定
   - 避免在恢复过程中中断容器

3. **恢复后验证**
   - 验证数据完整性
   - 检查应用程序连接
   - 更新数据库统计信息

4. **安全考虑**
   - 使用安全的rclone配置
   - 限制恢复容器的网络访问
   - 定期测试恢复流程
