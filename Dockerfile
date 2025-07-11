# 可配置的基础PostgreSQL镜像
ARG POSTGRES_IMAGE=postgres:17.5-alpine
ARG PGBACKREST_VERSION=2.55.1

# ===== 构建阶段：用于编译pgbackrest =====
FROM ${POSTGRES_IMAGE} AS builder

ARG PGBACKREST_VERSION

# 构建pgBackRest和下载rclone的单个优化层
RUN apk add --no-cache --virtual .build-deps \
        curl unzip build-base gcc make cmake musl-dev \
        openssl-dev lz4-dev zstd-dev bzip2-dev libxml2-dev \
        postgresql-dev libc-dev zlib-dev yaml-dev meson ninja \
    && curl -L https://github.com/pgbackrest/pgbackrest/archive/release/${PGBACKREST_VERSION}.tar.gz | tar -xz \
    && meson setup pgbackrest-release-${PGBACKREST_VERSION} /tmp/build \
    && ninja -C /tmp/build install \
    && strip /usr/local/bin/pgbackrest \
    && curl -L https://downloads.rclone.org/rclone-current-linux-amd64.zip -o rclone.zip \
    && unzip rclone.zip \
    && mv rclone-*/rclone /usr/local/bin/ \
    && chmod +x /usr/local/bin/rclone \
    && rm -rf /tmp/* /var/cache/apk/* pgbackrest-* rclone* \
    && apk del .build-deps

# ===== 最终运行阶段 =====
FROM ${POSTGRES_IMAGE}


LABEL maintainer="https://github.com/whispin/postgres_nrt_backup" \
      description="PostgreSQL with pgBackRest and rclone for near real-time backup" \
      version="1.0"


COPY --from=builder /usr/local/bin/pgbackrest /usr/local/bin/pgbackrest
COPY --from=builder /usr/local/bin/rclone /usr/bin/rclone

COPY src/ /backup/src/
COPY config/pgbackrest.conf /etc/pgbackrest/pgbackrest.conf


RUN apk add --no-cache bash gzip tar coreutils findutils dcron su-exec bc jq \
        openssl lz4 zstd bzip2 libxml2 zlib yaml \
        lz4-dev zstd-dev bzip2-dev libxml2-dev zlib-dev yaml-dev \
    && mkdir -p /etc/pgbackrest /var/log/pgbackrest /var/lib/pgbackrest \
                /backup/logs /backup/local/{base,wal} /var/lib/postgresql/data \
                ~/.config/rclone /var/spool/cron/crontabs \
    && chmod 750 /etc/pgbackrest /var/log/pgbackrest /var/lib/pgbackrest \
    && chmod 755 /var/spool/cron/crontabs \
    && chmod +x /backup/src/bin/*.sh /backup/src/core/*.sh \
    && chmod 640 /etc/pgbackrest/pgbackrest.conf \
    && chown -R postgres:postgres /backup /var/log/pgbackrest /var/lib/pgbackrest /etc/pgbackrest \
    && [ -f /usr/local/bin/docker-entrypoint.sh ] && \
       cp /usr/local/bin/docker-entrypoint.sh /usr/local/bin/postgres-docker-entrypoint.sh || true \
    && cp /backup/src/bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh \
    && chmod +x /usr/local/bin/docker-entrypoint.sh \
    && pgbackrest version \
    && rm -rf /var/cache/apk/*

# 环境变量（合并为单个ENV指令）
ENV PGBACKREST_CONFIG=/etc/pgbackrest/pgbackrest.conf \
    BACKUP_RETENTION_DAYS=3 \
    BASE_BACKUP_SCHEDULE="0 3 * * *" \
    INCREMENTAL_BACKUP_SCHEDULE="0 */6 * * *" \
    RCLONE_REMOTE_PATH="postgres-backups" \
    RECOVERY_MODE="false" \
    PGBACKREST_STANZA="" \
    WAL_GROWTH_THRESHOLD="100MB" \
    WAL_MONITOR_INTERVAL=60 \
    MIN_WAL_GROWTH_FOR_BACKUP="5MB" \
    ENABLE_WAL_MONITOR="true" \
    RECOVERY_TARGET_TIME="" \
    RECOVERY_TARGET_NAME="" \
    RECOVERY_TARGET_XID="" \
    RECOVERY_TARGET_LSN="" \
    RECOVERY_TARGET_INCLUSIVE="true" \
    RECOVERY_TARGET_ACTION="promote"

EXPOSE 5432

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD /backup/src/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]