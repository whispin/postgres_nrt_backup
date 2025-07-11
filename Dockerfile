# 可配置的基础PostgreSQL镜像
ARG POSTGRES_IMAGE=postgres:17.5-alpine
ARG PGBACKREST_VERSION=2.55.1

# ===== 构建阶段：用于编译pgbackrest =====
FROM ${POSTGRES_IMAGE} AS builder

ARG PGBACKREST_VERSION

# 安装编译依赖（仅在构建阶段）
RUN apk add --no-cache --virtual .build-deps \
    curl \
    unzip \
    build-base \
    gcc \
    make \
    cmake \
    musl-dev \
    openssl-dev \
    lz4-dev \
    zstd-dev \
    bzip2-dev \
    libxml2-dev \
    postgresql-dev \
    libc-dev \
    zlib-dev \
    yaml-dev \
    meson \
    ninja

# 编译pgBackRest
RUN curl -L -o ${PGBACKREST_VERSION}.tar.gz \
        https://github.com/pgbackrest/pgbackrest/archive/release/${PGBACKREST_VERSION}.tar.gz \
    && tar -xzf ${PGBACKREST_VERSION}.tar.gz \
    && rm -f ${PGBACKREST_VERSION}.tar.gz \
    && mkdir /tmp/pgbackrest-build \
    && meson setup pgbackrest-release-${PGBACKREST_VERSION} /tmp/pgbackrest-build \
    && ninja -C /tmp/pgbackrest-build \
    && ninja -C /tmp/pgbackrest-build install \
    && strip /usr/local/bin/pgbackrest

# 下载rclone（在构建阶段）
RUN curl -O https://downloads.rclone.org/rclone-current-linux-amd64.zip \
    && unzip rclone-current-linux-amd64.zip \
    && cd rclone-*-linux-amd64 \
    && cp rclone /usr/local/bin/ \
    && chmod +x /usr/local/bin/rclone \
    && cd .. \
    && rm -rf rclone-* rclone-current-linux-amd64.zip

# ===== 运行阶段：最终镜像 =====
FROM ${POSTGRES_IMAGE}

# 标签信息
LABEL maintainer="PostgreSQL NRT Backup Team"
LABEL description="PostgreSQL with pgBackRest and rclone for near real-time backup"
LABEL version="1.0"

# 安装运行时必需的包（包括开发库以支持动态链接的二进制文件）
RUN apk add --no-cache \
    bash \
    gzip \
    tar \
    coreutils \
    findutils \
    dcron \
    su-exec \
    bc \
    jq \
    openssl \
    openssl-dev \
    lz4 \
    lz4-dev \
    zstd \
    zstd-dev \
    bzip2 \
    bzip2-dev \
    libxml2 \
    libxml2-dev \
    zlib \
    zlib-dev \
    yaml \
    yaml-dev \
    && rm -rf /var/cache/apk/*

# 从构建阶段复制编译好的pgBackRest
COPY --from=builder /usr/local/bin/pgbackrest /usr/local/bin/pgbackrest

# 从构建阶段复制rclone
COPY --from=builder /usr/local/bin/rclone /usr/bin/rclone

# 复制备份脚本（在创建目录之前）
COPY src/ /backup/src/

# 创建必要的目录和配置
RUN mkdir -p /etc/pgbackrest /var/log/pgbackrest /var/lib/pgbackrest \
    /backup/logs /backup/local/base /backup/local/wal \
    /var/lib/postgresql/data ~/.config/rclone \
    /var/spool/cron/crontabs \
    && chmod 750 /etc/pgbackrest /var/log/pgbackrest /var/lib/pgbackrest \
    && chmod 755 /var/spool/cron/crontabs \
    && chown -R postgres:postgres /backup /var/log/pgbackrest /var/lib/pgbackrest /etc/pgbackrest

# 设置脚本权限
RUN chmod +x /backup/src/bin/*.sh && \
    chmod +x /backup/src/core/*.sh && \
    chown -R postgres:postgres /backup

# 保存原始的PostgreSQL入口点脚本（如果存在）
RUN if [ -f /usr/local/bin/docker-entrypoint.sh ]; then \
        cp /usr/local/bin/docker-entrypoint.sh /usr/local/bin/postgres-docker-entrypoint.sh; \
    fi

# 复制自定义入口点脚本并设置权限
RUN cp /backup/src/bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh && \
    chmod +x /usr/local/bin/docker-entrypoint.sh

# 验证pgBackRest安装
RUN pgbackrest version

# 复制pgbackrest基础配置文件
COPY config/pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
RUN chmod 640 /etc/pgbackrest/pgbackrest.conf && chown postgres:postgres /etc/pgbackrest/pgbackrest.conf

# 设置默认配置路径
ENV PGBACKREST_CONFIG=/etc/pgbackrest/pgbackrest.conf

# 设置默认环境变量
ENV BACKUP_RETENTION_DAYS=3
ENV BASE_BACKUP_SCHEDULE="0 3 * * *"
ENV INCREMENTAL_BACKUP_SCHEDULE="0 */6 * * *"
ENV RCLONE_REMOTE_PATH="postgres-backups"
ENV RECOVERY_MODE="false"
ENV PGBACKREST_STANZA=""
ENV WAL_GROWTH_THRESHOLD="100MB"
ENV WAL_MONITOR_INTERVAL=60
ENV MIN_WAL_GROWTH_FOR_BACKUP="1MB"
ENV ENABLE_WAL_MONITOR="true"
ENV RECOVERY_TARGET_TIME=""
ENV RECOVERY_TARGET_NAME=""
ENV RECOVERY_TARGET_XID=""
ENV RECOVERY_TARGET_LSN=""
ENV RECOVERY_TARGET_INCLUSIVE="true"
ENV RECOVERY_TARGET_ACTION="promote"
# rclone配置方式（二选一）：
# 1. RCLONE_CONF_BASE64 - Base64编码的rclone配置
# 2. 挂载rclone.conf文件到 /root/.config/rclone/rclone.conf

# 暴露PostgreSQL端口
EXPOSE 5432

# 添加健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /backup/src/bin/healthcheck.sh

# 设置启动命令
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]