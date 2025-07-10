# 构建阶段：用于编译pgbackrest
FROM postgres:17.5-alpine

# 安装编译依赖
RUN apk add --no-cache \
    curl \
    bash \
    gzip \
    tar \
    unzip \
    coreutils \
    findutils \
    dcron \
    su-exec \
    bc \
    jq \
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
    ninja \
    && rm -rf /var/cache/apk/*

# 安装pgBackRest从源码
ENV PGBACKREST_VERSION=2.55.1
RUN curl -L -o ${PGBACKREST_VERSION}.tar.gz https://github.com/pgbackrest/pgbackrest/archive/release/${PGBACKREST_VERSION}.tar.gz \
 && tar -xzf ${PGBACKREST_VERSION}.tar.gz \
 && rm -f ${PGBACKREST_VERSION}.tar.gz \
 && mkdir /tmp/pgbackrest-build \
 && meson setup pgbackrest-release-${PGBACKREST_VERSION} /tmp/pgbackrest-build \
 && ninja -C /tmp/pgbackrest-build \
 && ninja -C /tmp/pgbackrest-build install \
 && strip /usr/local/bin/pgbackrest


# 安装rclone
RUN curl -O https://downloads.rclone.org/rclone-current-linux-amd64.zip \
    && unzip rclone-current-linux-amd64.zip \
    && cd rclone-*-linux-amd64 \
    && cp rclone /usr/bin/ \
    && chmod +x /usr/bin/rclone \
    && cd .. \
    && rm -rf rclone-* rclone-current-linux-amd64.zip

# 创建必要的目录和配置
RUN mkdir -p /etc/pgbackrest /var/log/pgbackrest /var/lib/pgbackrest \
    /backup/scripts /backup/logs /backup/local/base /backup/local/wal \
    /var/lib/postgresql/data ~/.config/rclone \
    /var/spool/cron/crontabs \
    && chmod 750 /etc/pgbackrest /var/log/pgbackrest /var/lib/pgbackrest \
    && chmod 755 /var/spool/cron/crontabs \
    && chown -R postgres:postgres /backup /var/log/pgbackrest /var/lib/pgbackrest /etc/pgbackrest \
    && pgbackrest version

# 复制pgbackrest基础配置文件
COPY pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
RUN chmod 640 /etc/pgbackrest/pgbackrest.conf && chown postgres:postgres /etc/pgbackrest/pgbackrest.conf

# 设置默认配置路径
ENV PGBACKREST_CONFIG=/etc/pgbackrest/pgbackrest.conf

# 复制备份脚本
COPY scripts/ /backup/scripts/

# 设置脚本权限
RUN chmod +x /backup/scripts/*.sh && \
    chown -R postgres:postgres /backup/scripts

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

# 保存原始的PostgreSQL入口点脚本
RUN cp /usr/local/bin/docker-entrypoint.sh /usr/local/bin/postgres-docker-entrypoint.sh

# 复制自定义入口点脚本
COPY scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# 添加健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /backup/scripts/healthcheck.sh

# 设置启动命令
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]