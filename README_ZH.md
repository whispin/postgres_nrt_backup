# PostgreSQL 近实时备份和恢复系统

基于 pgBackRest 的 PostgreSQL 近实时备份和恢复解决方案，支持本地和RCLONE远程存储，具备完整的自动恢复功能。

> [English README](https://github.com/whispin/postgres_nrt_backup/blob/main/README.md) | **中文文档**

## ✨ 主要功能

- 🔄 **智能自动备份**: 定时完整备份和增量备份，支持智能触发机制
- 📊 **WAL增长监控**: 基于可配置的WAL增长阈值自动触发增量备份
- ⏰ **双重触发机制**: 支持基于时间(cron)和WAL增长的并行增量备份触发
- 🔍 **智能WAL检测**: 智能WAL变化检测，避免空备份，优化备份效率
- 🎯 **手动备份操作**: 支持手动触发全量、增量和差异备份
- 🧠 **智能备份逻辑**: 增量备份时自动检查基础备份，无基础备份时自动创建全量备份
- 🔧 **完全自动恢复**: 从远程存储完全自动恢复到最新备份或指定时间点
- 📁 **分离存储结构**: 不同类型备份存储在有组织的目录层次结构中
- ☁️ **多云存储支持**: 通过rclone集成支持Google Drive、AWS S3、Azure等多种云存储
- 📈 **全面监控**: 实时备份和恢复监控，详细日志记录
- 🛡️ **健康检查与恢复**: 内置健康检查、故障检测和自动恢复机制
- 🔒 **安全配置**: 支持RCLONE_CONF_BASE64环境变量和挂载配置文件两种方式

## 🚀 快速开始

### 备份模式

```bash
# 拉取最新镜像
docker pull ghcr.io/whispin/postgres_nrt_backup:latest

# 方式1：使用RCLONE_CONF_BASE64环境变量（推荐）
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

# 方式2：直接挂载rclone.conf文件
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

### 恢复模式

```bash
# 方式1：使用RCLONE_CONF_BASE64环境变量恢复到最新备份
docker run -d \
  --name postgres-recovery \
  -p 5432:5432 \
  -e POSTGRES_USER="root" \
  -e POSTGRES_PASSWORD="root123" \
  -e POSTGRES_DB="test_db" \
  -e RCLONE_CONF_BASE64="your_base64_encoded_rclone_config" \
  -e RECOVERY_MODE="true" \
  ghcr.io/whispin/postgres_nrt_backup:latest

# 方式2：挂载rclone.conf文件进行时间点恢复
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

### 使用 Docker Compose

```bash
# 使用 GHCR 镜像
docker-compose -f docker-compose.ghcr.yml up -d
```

## 🧪 测试示例

以下是测试备份系统的完整示例：

```bash
# 1. 启动带有测试配置的备份容器
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

# 2. 创建测试数据以触发WAL增长
docker exec postgres-backup-test psql -U root -d test_db -c "
CREATE TABLE test_table AS
SELECT generate_series(1, 10000) as id,
       'Test data ' || generate_series(1, 10000) as description;
SELECT pg_switch_wal();"

# 3. 检查备份状态
docker exec postgres-backup-test pgbackrest --stanza=main info

# 4. 监控日志
docker logs postgres-backup-test --tail 20

# 5. 测试恢复
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

## 📦 镜像信息

### 可用标签
- `latest` - 最新稳定版本
- `main-<sha>` - 特定提交版本
- `pr-<number>` - PR 构建版本（仅用于测试）

### 镜像大小优化
- 使用多阶段构建
- 分离编译环境和运行环境
- 只保留运行时必需的依赖
- 正确安装共享库文件（`*-libs` 包）
- 预计镜像大小减少 150-300MB

## ⚙️ 配置选项

### 环境变量

| 变量名 | 默认值 | 说明 |
|--------|--------|------|
| `POSTGRES_USER` | - | PostgreSQL 用户名（必需） |
| `POSTGRES_PASSWORD` | - | PostgreSQL 密码（必需） |
| `POSTGRES_DB` | - | PostgreSQL 数据库名（必需） |
| `PGBACKREST_STANZA` | `main` | pgBackRest 存储库名称 |
| `BACKUP_RETENTION_DAYS` | `3` | 备份保留天数 |
| `BASE_BACKUP_SCHEDULE` | `"0 3 * * *"` | 全量备份计划（cron 格式） |
| `INCREMENTAL_BACKUP_SCHEDULE` | `"0 */6 * * *"` | 增量备份计划（cron 格式） |
| `RCLONE_CONF_BASE64` | - | Base64编码的rclone配置（云存储必需） |
| `RCLONE_REMOTE_PATH` | `"postgres-backups"` | 远程存储路径 |
| `RECOVERY_MODE` | `"false"` | 恢复模式开关 |
| `WAL_GROWTH_THRESHOLD` | `"100MB"` | WAL增长阈值，用于自动触发增量备份 |
| `WAL_MONITOR_INTERVAL` | `60` | WAL监控检查间隔（秒） |
| `ENABLE_WAL_MONITOR` | `"true"` | 启用WAL增长监控 |
| `MIN_WAL_GROWTH_FOR_BACKUP` | `"1MB"` | 定时增量备份的最小WAL增长阈值 |

### 恢复环境变量

| 变量名 | 默认值 | 说明 |
|--------|--------|------|
| `RECOVERY_MODE` | `"false"` | 启用恢复模式 |
| `RECOVERY_TARGET_TIME` | - | 恢复目标时间 (YYYY-MM-DD HH:MM:SS) |
| `RECOVERY_TARGET_NAME` | - | 恢复目标名称 |
| `RECOVERY_TARGET_XID` | - | 恢复目标事务ID |
| `RECOVERY_TARGET_LSN` | - | 恢复目标LSN |
| `RECOVERY_TARGET_INCLUSIVE` | `"true"` | 包含恢复目标 |
| `RECOVERY_TARGET_ACTION` | `"promote"` | 恢复后操作 |

### rclone配置（选择一种方式）

#### 方式1：环境变量
```bash
# 将rclone.conf编码为base64
RCLONE_CONF_BASE64=$(cat rclone.conf | base64 -w 0)

# 在docker run中使用
docker run -e RCLONE_CONF_BASE64="$RCLONE_CONF_BASE64" ...
```

#### 方式2：文件挂载
```bash
# 直接挂载rclone.conf
docker run -v /path/to/rclone.conf:/root/.config/rclone/rclone.conf:ro ...
```

### 卷挂载

| 路径 | 说明 | 权限 |
|------|------|------|
| `/var/lib/postgresql/data` | PostgreSQL 数据目录 | 只读 |
| `/backup/local` | 本地备份存储 | 读写 |
| `/backup/logs` | 备份日志 | 读写 |
| `/root/.config/rclone/rclone.conf` | rclone 配置文件 | 只读 |

## 🔧 手动操作

### 手动备份命令

```bash
# 全量备份
docker exec postgres-backup /backup/src/bin/backup.sh

# 增量备份（无基础备份时自动创建全量备份）
docker exec postgres-backup /backup/src/bin/incremental-backup.sh

# 手动备份选项
docker exec postgres-backup /backup/src/bin/manual-backup.sh --full
docker exec postgres-backup /backup/src/bin/manual-backup.sh --incremental
docker exec postgres-backup /backup/src/bin/manual-backup.sh --diff

# 检查备份状态
docker exec postgres-backup pgbackrest --stanza=main info

# 列出可用备份
docker exec postgres-backup pgbackrest --stanza=main info --output=json
```

### WAL监控控制

```bash
# 检查WAL监控状态
docker exec postgres-backup /backup/src/bin/wal-control.sh status

# 查看WAL监控日志
docker exec postgres-backup /backup/src/bin/wal-control.sh logs

# 强制增量备份
docker exec postgres-backup /backup/src/bin/wal-control.sh force-backup

# 重启WAL监控
docker exec postgres-backup /backup/src/bin/wal-control.sh restart

# 检查当前WAL增长
docker logs postgres-backup --tail 20
```

### 恢复控制

```bash
# 显示恢复配置
docker exec postgres-recovery /backup/src/bin/recovery-control.sh show-config

# 列出远程存储的可用备份
docker exec postgres-recovery /backup/src/bin/recovery-control.sh list-backups

# 测试远程存储连接
docker exec postgres-recovery /backup/src/bin/recovery-control.sh test-connection

# 准备恢复
docker exec postgres-recovery /backup/src/bin/recovery-control.sh prepare-recovery
```

## 📁 备份目录结构

系统使用分离的目录结构存储不同类型的备份：

```
postgres-backups/
└── {数据库名}/
    ├── full-backups/           # 全量备份归档
    │   ├── pgbackrest_main_20250711_073855.tar.gz
    │   ├── full_backup_20250711_073855.json
    │   └── ...
    ├── incremental-backups/    # 增量备份元数据
    │   ├── incremental_backup_20250711_074036.json
    │   ├── wal_incremental_backup_20250711_080000.json
    │   └── ...
    ├── differential-backups/   # 差异备份元数据
    │   ├── differential_backup_20250711_170000.json
    │   └── ...
    └── repository/             # pgBackRest存储库（完整备份数据）
        ├── archive/            # WAL归档文件
        │   └── main/
        │       └── 17-1/
        ├── backup/             # 备份数据文件
        │   └── main/
        │       ├── 20250711-073641F/          # 全量备份
        │       ├── 20250711-073641F_20250711-074028I/  # 增量备份
        │       └── ...
        └── backup.info         # 备份元数据
```

## 🔧 构建和开发

### 本地构建

```bash
# 构建优化后的镜像
docker build -t postgres-backup:local .

# 比较镜像大小
./compare-image-sizes.sh
```

### 开发环境

```bash
# 克隆仓库
git clone https://github.com/whispin/postgres_nrt_backup.git
cd postgres_nrt_backup

# 构建和测试
./test-build.sh
```

## 📋 功能特性

### ✅ **备份功能**
- **pgBackRest集成**: 行业标准的PostgreSQL备份工具，经过验证的可靠性
- **多种备份类型**: 全量、增量和差异备份，支持智能备份链
- **双重触发系统**: 基于时间(cron)和WAL增长的自动备份触发机制
- **智能备份逻辑**: 请求增量备份时自动检查并创建基础全量备份
- **WAL增长监控**: 可配置阈值（MB/KB单位）的自动增量备份
- **空备份预防**: 智能WAL变化检测，避免不必要的备份操作

### ✅ **存储与恢复**
- **多云支持**: Google Drive、AWS S3、Azure Blob等40+云存储提供商
- **时间点恢复(PITR)**: 恢复到特定时间戳、事务ID或LSN
- **自动恢复模式**: 从远程存储完全自动化恢复
- **分离目录结构**: 不同备份类型和元数据的有组织存储

### ✅ **监控与操作**
- **实时监控**: 全面的日志记录和状态报告
- **健康检查**: 内置健康监控和故障检测
- **手动操作**: 支持手动备份触发和管理命令
- **灵活配置**: 基于环境变量的配置，具有合理的默认值

## 🔄 CI/CD

项目使用 GitHub Actions 自动构建和发布：

- **触发条件**: 推送到 main 分支或创建 PR
- **构建平台**: Ubuntu Latest
- **发布目标**: GitHub Container Registry (ghcr.io)
- **缓存**: 使用 GitHub Actions 缓存优化构建速度


## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

MIT License
