#!/usr/bin/env bash
#=================================================
# PostgreSQL 容器入口脚本
# 功能：
#   1. 运行内存自动计算脚本，生成动态调优配置
#   2. 将调优配置写入 PostgreSQL 自动配置目录
#   3. 兼容 Percona Operator / Patroni（若由其接管则直接透传）
#   4. 独立运行时初始化并启动 PostgreSQL
#=================================================

set -euo pipefail

# ==============================================================================
# 修正 Percona Operator 3.0.0 注入的错误 locale
# Bug: Operator 硬编码 LANG/LC_ALL=en_US.utf-8（小写 utf-8，无效）
# Fix: 强制使用镜像内置的正确 locale zh_CN.UTF-8
# ==============================================================================
export LANG=zh_CN.UTF-8
export LC_ALL=zh_CN.UTF-8

PGHOME="${PGHOME:-/data/postgres}"
PGDATA="${PGDATA:-/data/postgres/data}"
PG_MAJOR="${PG_MAJOR:-17}"
PGBIN="/usr/lib/postgresql/${PG_MAJOR}/bin"
AUTO_CONF_DIR="${PGHOME}/conf.d"
TUNER="/usr/local/bin/postgresql-config-tuner.sh"

# ==============================================================================
# 生成动态调优配置文件（供 include 使用）
# ==============================================================================
generate_tuned_config() {
    mkdir -p "${AUTO_CONF_DIR}"
    echo ">>> [entrypoint] 根据容器资源自动计算 PostgreSQL 内存参数..."
    "${TUNER}" conf > "${AUTO_CONF_DIR}/00-auto-tuned.conf"
    echo ">>> [entrypoint] 已生成 ${AUTO_CONF_DIR}/00-auto-tuned.conf:"
    cat "${AUTO_CONF_DIR}/00-auto-tuned.conf"
}

# ==============================================================================
# 场景 1：由 Patroni 接管（Percona Operator 环境）
# Patroni 会以 `patroni /path/to/config.yml` 方式启动，
# 此时仅生成调优片段供 Patroni 的 postgresql.parameters 参考，然后透传执行
# ==============================================================================
if [ "${1:-}" = "patroni" ] || [[ "${1:-}" == *"patroni"* ]]; then
    generate_tuned_config || echo ">>> [entrypoint] 调优配置生成失败（非致命），继续启动 Patroni"
    echo ">>> [entrypoint] 检测到 Patroni 启动命令，透传执行: $*"
    exec "$@"
fi

# ==============================================================================
# 场景 2：容器编排系统（如 Percona Operator）直接以 postgres 用户运行其他命令
# 若第一个参数不是 postgres，直接透传（如 sleep、bash 等诊断命令）
# ==============================================================================
if [ "${1:-}" != "postgres" ]; then
    exec "$@"
fi

# ==============================================================================
# 场景 3：独立运行 PostgreSQL（非 Operator 环境，用于本地测试）
# ==============================================================================
echo ">>> [entrypoint] 独立模式启动 PostgreSQL..."

# 若数据目录未初始化则执行 initdb
if [ ! -s "${PGDATA}/PG_VERSION" ]; then
    echo ">>> [entrypoint] 初始化数据目录 ${PGDATA}..."
    mkdir -p "${PGDATA}"
    chmod 0700 "${PGDATA}"
    "${PGBIN}/initdb" \
        --username="${POSTGRES_USER:-postgres}" \
        --pwfile=<(echo "${POSTGRES_PASSWORD:-postgres}") \
        --encoding=UTF8 \
        --locale=zh_CN.UTF-8 \
        -D "${PGDATA}"

    # 在主配置中引入自动调优目录
    echo "include_dir = '${AUTO_CONF_DIR}'" >> "${PGDATA}/postgresql.conf"

    # 允许容器网络连接
    echo "host all all 0.0.0.0/0 scram-sha-256" >> "${PGDATA}/pg_hba.conf"
    echo "listen_addresses = '*'" >> "${PGDATA}/postgresql.conf"

    # 预加载扩展库
    echo "shared_preload_libraries = 'timescaledb,pg_stat_monitor'" >> "${PGDATA}/postgresql.conf"
fi

# 每次启动都重新计算调优配置（内存/CPU 可能变化）
generate_tuned_config

echo ">>> [entrypoint] 启动 postgres..."
exec "${PGBIN}/postgres" -D "${PGDATA}"
