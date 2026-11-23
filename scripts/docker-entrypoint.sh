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
# 生成动态调优配置文件（供 include_dir 引入）
# 参数按容器 CPU / 内存自动计算（连接数、缓冲区、WAL、并行、autovacuum、IO 等），
# 生成内容带中文注释说明每项的计算公式；每次启动重新生成，跟随资源变化
# ==============================================================================
generate_tuned_config() {
    mkdir -p "${AUTO_CONF_DIR}"
    echo ">>> [entrypoint] 根据容器 CPU / 内存自动计算 PostgreSQL 参数..."
    "${TUNER}" conf > "${AUTO_CONF_DIR}/00-auto-tuned.conf"
    echo ">>> [entrypoint] 已生成 ${AUTO_CONF_DIR}/00-auto-tuned.conf"
    # 摘要打印到容器日志，方便确认本次生效的资源与关键参数
    "${TUNER}" summary
}

# ==============================================================================
# 确保主配置包含自动调优目录（兼容旧数据目录：老版本镜像未写入 include_dir）
# ==============================================================================
ensure_include_dir() {
    local conf="${PGDATA}/postgresql.conf"
    [ -f "$conf" ] || return 0
    if grep -qE "^[[:space:]]*include_dir[[:space:]]*=" "$conf"; then
        return 0
    fi
    echo ">>> [entrypoint] 主配置缺少 include_dir，自动追加 ${AUTO_CONF_DIR}"
    printf "\ninclude_dir = '%s'\n" "$AUTO_CONF_DIR" >> "$conf"
}

# ==============================================================================
# 创建应用数据库（POSTGRES_DB 与超级用户同名时由 initdb 自动建立，无需处理）
#   仅在首次初始化时执行：临时以本地 socket 启动、建库、再关闭
# ==============================================================================
create_app_database() {
    local db="${POSTGRES_DB:-}"
    local user="${POSTGRES_USER:-postgres}"
    [ -n "${db}" ] || return 0
    [ "${db}" = "${user}" ] && return 0
    [ "${NEED_CREATE_DB:-0}" = "1" ] || return 0

    local conf="${PGDATA}/postgresql.conf"
    cp -a "${conf}" "${conf}.bootstrap.bak"
    # 初始化期间仅监听本地 socket，避免短暂对外暴露
    printf "\nlisten_addresses = ''\n" >> "${conf}"
    # 库名只允许常规标识符字符，避免注入/引号问题
    case "${db}" in
        *[!A-Za-z0-9_-]*)
            echo ">>> [entrypoint] ERROR: POSTGRES_DB 含非法字符（仅支持字母/数字/下划线/短横线）: ${db}" >&2
            return 1 ;;
    esac

    echo ">>> [entrypoint] 创建数据库 ${db} ..."
    "${PGBIN}/pg_ctl" -D "${PGDATA}" -l "${PGHOME}/logs/bootstrap.log" -w -t 120 start
    if ! "${PGBIN}/psql" -h /var/run/postgresql -U "${user}" -d postgres -v ON_ERROR_STOP=1 \
            -tAc "SELECT 1 FROM pg_database WHERE datname = '${db}'" | grep -q 1; then
        "${PGBIN}/psql" -h /var/run/postgresql -U "${user}" -d postgres -v ON_ERROR_STOP=1 \
            -c "CREATE DATABASE \"${db}\""
    fi
    "${PGBIN}/pg_ctl" -D "${PGDATA}" -m fast -w stop
    mv -f "${conf}.bootstrap.bak" "${conf}"
    echo ">>> [entrypoint] 数据库 ${db} 就绪"
}

# ==============================================================================
# 场景 0：以 root 启动（compose 挂载宿主目录时需要）
#   修正挂载目录属主（宿主目录默认 root 属主，postgres 用户无法写入），
#   随后降权到 postgres(26) 重新执行本脚本
# ==============================================================================
if [ "$(id -u)" = "0" ]; then
    echo ">>> [entrypoint] 以 root 启动，修正数据目录属主后降权到 postgres"
    mkdir -p "${PGHOME}/data" "${PGHOME}/logs" "${PGHOME}/run" \
             "${PGHOME}/archive" "${PGHOME}/conf.d" /var/run/postgresql /var/log/postgresql
    for d in "${PGHOME}" "${PGHOME}/data" "${PGHOME}/logs" "${PGHOME}/run" \
             "${PGHOME}/archive" "${PGHOME}/conf.d" /var/run/postgresql /var/log/postgresql; do
        # 已由 postgres 拥有的目录不递归处理，避免大数据目录启动变慢
        if [ "$(stat -c %u "${d}")" != "26" ]; then
            chown -R postgres:postgres "${d}"
        fi
    done
    exec gosu postgres "$0" "$@"
fi

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
        --pwfile=<(echo "${POSTGRES_PASSWORD:-ysyh!9Sky}") \
        --encoding=UTF8 \
        --locale=zh_CN.UTF-8 \
        --auth-local=trust \
        --auth-host=scram-sha-256 \
        -D "${PGDATA}"

    # 允许容器网络连接
    echo "host all all 0.0.0.0/0 scram-sha-256" >> "${PGDATA}/pg_hba.conf"
    echo "listen_addresses = '*'" >> "${PGDATA}/postgresql.conf"
    # shared_preload_libraries / 内存参数全部由自动调优配置提供，此处不再重复写入
    NEED_CREATE_DB=1
fi

# 确保主配置引入自动调优目录（旧数据目录自动补齐）
ensure_include_dir

# 每次启动都重新计算调优配置（内存/CPU 可能变化）
generate_tuned_config

# 首次初始化后创建 POSTGRES_DB（与官方镜像行为一致）
create_app_database

echo ">>> [entrypoint] 启动 postgres..."
exec "${PGBIN}/postgres" -D "${PGDATA}"
