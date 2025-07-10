# PostgreSQL 近实时备份和恢复系统

基于 pgBackRest 的 PostgreSQL 近实时备份和恢复解决方案，支持本地和RCLONE远程存储，具备完整的自动恢复功能。

> [English README](README.md) | **中文文档**

## ✨ 主要功能

- 🔄 **自动备份**: 定时完整备份和增量备份
- 📊 **WAL监控**: 基于WAL增长自动触发增量备份
- ⏰ **双重触发**: 支持基于时间(cron)和WAL增长的双重增量备份触发
- 🔍 **智能WAL检测**: 检查WAL变化避免空备份，提高备份效率
- 🎯 **手动备份**: 支持手动触发各种类型备份
- 🧠 **智能备份**: 增量备份时自动检查并创建全量备份
- 🔧 **自动恢复**: 从远程存储自动恢复到指定时间点
- 📁 **分离存储**: 不同类型备份存储在独立目录中
- ☁️ **云存储**: 通过rclone支持多种云存储
- 📈 **监控日志**: 完整的备份和恢复监控
- 🛡️ **健康检查**: 内置健康检查和故障恢复

## 🚀 快速开始

### 备份模式

```bash
# 拉取最新镜像
docker pull ghcr.io/whispin/postgres_nrt_backup:latest

# 方式1：使用RCLONE_CONF_BASE64环境变量
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

# 方式2：直接挂载rclone.conf文件
docker run -d \
  --name postgres-backup \
  -e POSTGRES_USER=myuser \
  -e POSTGRES_PASSWORD=mypass \
  -e POSTGRES_DB=mydb \
  -e PGBACKREST_STANZA=main \
  -e WAL_GROWTH_THRESHOLD="100MB" \
  -v /path/to/postgres/data:/var/lib/postgresql/data:ro \
  -v /path/to/backup:/backup/local \
  -v /path/to/rclone.conf:/root/.config/rclone/rclone.conf:ro \
  ghcr.io/whispin/postgres_nrt_backup:latest
```

### 恢复模式

```bash
# 方式1：使用RCLONE_CONF_BASE64环境变量恢复到最新备份
docker run -d \
  --name postgres-recovery \
  -e POSTGRES_USER=myuser \
  -e POSTGRES_PASSWORD=mypass \
  -e POSTGRES_DB=mydb \
  -e RCLONE_CONF_BASE64="your_base64_config" \
  -e RECOVERY_MODE="true" \
  ghcr.io/whispin/postgres_nrt_backup:latest

# 方式2：挂载rclone.conf文件进行时间点恢复
docker run -d \
  --name postgres-recovery \
  -e POSTGRES_USER=myuser \
  -e POSTGRES_PASSWORD=mypass \
  -e POSTGRES_DB=mydb \
  -e RECOVERY_MODE="true" \
  -e RECOVERY_TARGET_TIME="2025-07-10 14:30:00" \
  -v /path/to/rclone.conf:/root/.config/rclone/rclone.conf:ro \
  ghcr.io/whispin/postgres_nrt_backup:latest
```

### 使用 Docker Compose

```bash
# 使用 GHCR 镜像
docker-compose -f docker-compose.ghcr.yml up -d
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
| `POSTGRES_USER` | - | PostgreSQL 用户名 |
| `POSTGRES_PASSWORD` | - | PostgreSQL 密码 |
| `POSTGRES_DB` | - | PostgreSQL 数据库名 |
| `PGBACKREST_STANZA` | `main` | pgBackRest 存储库名称 |
| `BACKUP_RETENTION_DAYS` | `3` | 备份保留天数 |
| `BASE_BACKUP_SCHEDULE` | `"0 3 * * *"` | 全量备份计划（cron 格式） |
| `INCREMENTAL_BACKUP_SCHEDULE` | `"0 */6 * * *"` | 增量备份计划（cron 格式） |
| `RCLONE_CONF_BASE64` | - | Base64编码的rclone配置（可选，如果挂载文件） |
| `RCLONE_REMOTE_PATH` | `"postgres-backups"` | 远程存储路径 |
| `RECOVERY_MODE` | `"false"` | 恢复模式开关 |
| `WAL_GROWTH_THRESHOLD` | `"100MB"` | WAL增长阈值 |
| `WAL_MONITOR_INTERVAL` | `60` | WAL监控间隔（秒） |
| `ENABLE_WAL_MONITOR` | `"true"` | 启用WAL监控 |
| `MIN_WAL_GROWTH_FOR_BACKUP` | `"1MB"` | 定时备份的最小WAL增长阈值 |

### 卷挂载

| 路径 | 说明 | 权限 |
|------|------|------|
| `/var/lib/postgresql/data` | PostgreSQL 数据目录 | 只读 |
| `/backup/local` | 本地备份存储 | 读写 |
| `/backup/logs` | 备份日志 | 读写 |
| `/root/.config/rclone/rclone.conf` | rclone 配置文件 | 只读 |

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

- ✅ 基于 pgBackRest 的可靠备份
- ✅ 支持增量和差异备份
- ✅ 自动备份调度（cron）
- ✅ 远程存储支持（rclone）
- ✅ 健康检查和监控
- ✅ 灵活的配置选项
- ✅ 优化的 Docker 镜像大小

## 🔄 CI/CD

项目使用 GitHub Actions 自动构建和发布：

- **触发条件**: 推送到 main 分支或创建 PR
- **构建平台**: Ubuntu Latest
- **发布目标**: GitHub Container Registry (ghcr.io)
- **缓存**: 使用 GitHub Actions 缓存优化构建速度

## 📚 文档

- [手动备份指南](MANUAL_BACKUP_GUIDE.md)
- [WAL监控指南](WAL_MONITOR_GUIDE.md)
- [恢复功能指南](RECOVERY_GUIDE.md)

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

MIT License
