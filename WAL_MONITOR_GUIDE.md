# WAL监控自动增量备份指南

## 概述

WAL（Write-Ahead Logging）监控功能可以根据WAL文件的增长大小自动触发增量备份。当WAL文件增长超过指定阈值时，系统会自动执行增量备份并上传到云端存储。

## 功能特性

- ✅ 基于WAL增长大小的自动触发
- ✅ 支持KB、MB、GB单位设置
- ✅ 精确的LSN（Log Sequence Number）跟踪
- ✅ 智能全量备份检查（无全量备份时自动创建）
- ✅ 自动上传到远程存储
- ✅ 完整的状态管理和日志记录
- ✅ 手动控制和监控功能

## 环境变量配置

### 必需的环境变量

| 变量名 | 默认值 | 描述 |
|--------|--------|------|
| `WAL_GROWTH_THRESHOLD` | `100MB` | WAL增长阈值，支持KB/MB/GB |
| `WAL_MONITOR_INTERVAL` | `60` | 检查间隔（秒） |
| `ENABLE_WAL_MONITOR` | `true` | 是否启用WAL监控 |

### 示例配置

```bash
# Docker运行示例
docker run -d --name postgres-backup \
    -e POSTGRES_USER=myuser \
    -e POSTGRES_PASSWORD=mypass \
    -e POSTGRES_DB=mydb \
    -e RCLONE_CONF_BASE64="your_base64_config" \
    -e WAL_GROWTH_THRESHOLD="50MB" \
    -e WAL_MONITOR_INTERVAL=30 \
    -e ENABLE_WAL_MONITOR="true" \
    your-postgres-backup-image
```

## WAL监控控制

### 基本命令

```bash
# 检查WAL监控状态
docker exec postgres-backup /backup/scripts/wal-control.sh status

# 查看WAL监控日志
docker exec postgres-backup /backup/scripts/wal-control.sh logs

# 手动触发增量备份
docker exec postgres-backup /backup/scripts/wal-control.sh force-backup
```

### 完整命令列表

| 命令 | 描述 |
|------|------|
| `start` | 启动WAL监控 |
| `stop` | 停止WAL监控 |
| `restart` | 重启WAL监控 |
| `status` | 显示状态信息 |
| `logs` | 显示日志 |
| `reset` | 重置状态 |
| `config` | 显示配置 |
| `force-backup` | 强制执行备份 |

## 工作原理

### 1. WAL增长监控

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   PostgreSQL    │───▶│   WAL Monitor    │───▶│  Incremental    │
│   WAL Files     │    │   (LSN Tracking) │    │    Backup       │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                                │
                                ▼
                       ┌──────────────────┐
                       │  Remote Storage  │
                       │   (via rclone)   │
                       └──────────────────┘
```

### 2. 监控流程

1. **初始化**: 记录当前LSN位置
2. **定期检查**: 按设定间隔检查WAL增长
3. **阈值判断**: 累计增长超过阈值时触发备份
4. **全量备份检查**: 检查是否存在全量备份，如无则先创建
5. **执行备份**: 调用pgBackRest执行增量备份
6. **上传存储**: 通过rclone上传到远程存储
7. **状态重置**: 重置累计计数器

### 3. LSN跟踪

系统使用PostgreSQL的LSN（Log Sequence Number）来精确跟踪WAL的增长：

```sql
-- 获取当前LSN
SELECT pg_current_wal_lsn();

-- 计算LSN差值（字节数）
SELECT pg_wal_lsn_diff('0/3000028', '0/2000000');
```

## 使用示例

### 1. 基本监控

```bash
# 启动容器，设置50MB阈值，30秒检查间隔
docker run -d --name postgres-backup \
    -e WAL_GROWTH_THRESHOLD="50MB" \
    -e WAL_MONITOR_INTERVAL=30 \
    your-postgres-backup-image

# 检查状态
docker exec postgres-backup /backup/scripts/wal-control.sh status
```

### 2. 高频监控

```bash
# 高频监控：10MB阈值，15秒检查
docker run -d --name postgres-backup \
    -e WAL_GROWTH_THRESHOLD="10MB" \
    -e WAL_MONITOR_INTERVAL=15 \
    your-postgres-backup-image
```

### 3. 大数据库监控

```bash
# 大数据库：1GB阈值，5分钟检查
docker run -d --name postgres-backup \
    -e WAL_GROWTH_THRESHOLD="1GB" \
    -e WAL_MONITOR_INTERVAL=300 \
    your-postgres-backup-image
```

## 监控和调试

### 1. 实时监控

```bash
# 实时查看WAL监控日志
docker exec postgres-backup /backup/scripts/wal-control.sh logs --follow

# 查看最近100行日志
docker exec postgres-backup /backup/scripts/wal-control.sh logs -n 100
```

### 2. 状态检查

```bash
# 详细状态信息
docker exec postgres-backup /backup/scripts/wal-control.sh status

# 输出示例：
# === WAL Monitor Status ===
# Status: RUNNING
# PID: 123
# 
# Configuration:
#   WAL Growth Threshold: 50MB
#   Monitor Interval: 30s
#   Enable WAL Monitor: true
# 
# Current State:
#   Last Backup Time: 2025-07-10 10:30:15
#   Last Backup LSN: 0/3A000028
#   Accumulated WAL Growth: 15728640 bytes
```

### 3. 手动测试

```bash
# 生成测试数据触发WAL增长
docker exec postgres-backup psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
CREATE TABLE test_wal AS 
SELECT generate_series(1,100000) as id, 
       md5(random()::text) as data;
"

# 强制WAL切换
docker exec postgres-backup psql -U $POSTGRES_USER -d $POSTGRES_DB -c "
SELECT pg_switch_wal();
"

# 检查是否触发备份
docker exec postgres-backup /backup/scripts/wal-control.sh logs -n 20
```

## 故障排除

### 常见问题

1. **WAL监控未启动**
   ```bash
   # 检查环境变量
   docker exec postgres-backup env | grep WAL
   
   # 手动启动
   docker exec postgres-backup /backup/scripts/wal-control.sh start
   ```

2. **备份未触发**
   ```bash
   # 检查阈值设置
   docker exec postgres-backup /backup/scripts/wal-control.sh config
   
   # 查看累计增长
   docker exec postgres-backup /backup/scripts/wal-control.sh status
   ```

3. **上传失败**
   ```bash
   # 检查rclone配置
   docker exec postgres-backup rclone config show
   
   # 测试连接
   docker exec postgres-backup rclone lsd remote:
   ```

### 调试模式

```bash
# 启用详细日志
docker run -d --name postgres-backup \
    -e WAL_GROWTH_THRESHOLD="10MB" \
    -e WAL_MONITOR_INTERVAL=15 \
    -e DEBUG="true" \
    your-postgres-backup-image
```

## 最佳实践

1. **阈值设置**
   - 小型数据库：10-50MB
   - 中型数据库：50-200MB  
   - 大型数据库：200MB-1GB

2. **检查间隔**
   - 高频写入：15-30秒
   - 正常负载：60-120秒
   - 低频写入：300-600秒

3. **监控建议**
   - 定期检查WAL监控状态
   - 监控备份日志中的错误
   - 验证远程存储上传
   - 定期测试备份恢复

4. **性能优化**
   - 避免过小的阈值导致频繁备份
   - 根据业务特点调整检查间隔
   - 监控系统资源使用情况
