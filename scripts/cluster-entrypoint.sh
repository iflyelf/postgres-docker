#!/usr/bin/env bash
# ==============================================================================
# 集群模式容器入口（PostgreSQL 节点：Patroni + PostgreSQL）
#
# 两种 etcd 部署方式：
#   ETCD_EMBEDDED=true （默认）本容器内同时启动 etcd，每节点一个容器，适合轻量场景
#   ETCD_EMBEDDED=false       使用独立 etcd 容器（docker-compose.cluster.yml 默认），生产推荐
#
# 容器以 root 启动 → 修正数据目录属主 → 以 postgres(26) 启动 etcd →
# 渲染 Patroni 配置（含自动调优参数）→ 以 postgres(26) 启动 Patroni
#
# 依赖环境变量（见 docker-compose.cluster.yml）：
#   PATRONI_NAME / PATRONI_CONNECT_HOST / ETCD_HOSTS / PATRONI_SCOPE
#   ETCD_NAME / ETCD_INITIAL_CLUSTER / ETCD_INITIAL_ADVERTISE_PEER_URLS
#   ETCD_ADVERTISE_CLIENT_URLS / ETCD_INITIAL_CLUSTER_TOKEN
#   POSTGRES_USER / POSTGRES_PASSWORD / REPLICATION_PASSWORD / REWIND_PASSWORD
# 可选：
#   CLUSTER_AUTOTUNE=false   关闭自动调优参数合并
#   PG_MEMORY_LIMIT / PG_CPU_LIMIT / PG_MAX_CONNECTIONS  手动指定资源
# ==============================================================================
set -Eeuo pipefail

log() { echo ">>> [cluster-entrypoint] $*"; }

# 非 patroni 命令（bash/psql/patronictl 等诊断）直接透传
if [ "${1:-}" != "patroni" ] && [ "${1:-}" != "" ]; then
    exec "$@"
fi

PG_MAJOR="${PG_MAJOR:-17}"
# 是否在本容器内启动 etcd；独立 etcd 容器部署时设为 false
ETCD_EMBEDDED="${ETCD_EMBEDDED:-true}"
PGHOME="${PGHOME:-/data/postgres}"
PGDATA="${PGDATA:-${PGHOME}/data}"
ETCD_DATA_DIR="${ETCD_DATA_DIR:-/data/etcd}"
ETCD_NAME="${ETCD_NAME:-pg1}"
# 如需强制引导状态可显式设置 ETCD_INITIAL_CLUSTER_STATE(new/existing)；默认按数据目录自动判断
ETCD_INITIAL_CLUSTER_TOKEN="${ETCD_INITIAL_CLUSTER_TOKEN:-postgres-cluster}"
ETCD_QUOTA_BACKEND_BYTES="${ETCD_QUOTA_BACKEND_BYTES:-4294967296}"
TEMPLATE="${PATRONI_TEMPLATE:-/etc/patroni/patroni.yml.tmpl}"
RENDERED="${PATRONI_CONFIG:-/run/patroni/patroni.yml}"
export PG_MAJOR

: "${PATRONI_NAME:?请设置 PATRONI_NAME（如 pg1）}"
: "${PATRONI_CONNECT_HOST:?请设置 PATRONI_CONNECT_HOST（如 pg1）}"
: "${ETCD_HOSTS:?请设置 ETCD_HOSTS（如 pg1:2379,pg2:2379,pg3:2379）}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-ysyh!9Sky}"
export POSTGRES_PASSWORD

# 嵌入式 etcd 模式才需要这些引导参数（独立 etcd 容器时由 etcd-entrypoint.sh 使用）
if [ "${ETCD_EMBEDDED}" = "true" ]; then
    : "${ETCD_NAME:?请设置 ETCD_NAME（如 pg1）}"
    : "${ETCD_INITIAL_CLUSTER:?请设置 ETCD_INITIAL_CLUSTER}"
    : "${ETCD_INITIAL_ADVERTISE_PEER_URLS:?请设置 ETCD_INITIAL_ADVERTISE_PEER_URLS}"
    : "${ETCD_ADVERTISE_CLIENT_URLS:?请设置 ETCD_ADVERTISE_CLIENT_URLS}"
fi

PATRONI_SCOPE="${PATRONI_SCOPE:-postgres-cluster}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
REPLICATION_PASSWORD="${REPLICATION_PASSWORD:-repl-pass}"
REWIND_PASSWORD="${REWIND_PASSWORD:-rewind-pass}"
PATRONI_LOG_LEVEL="${PATRONI_LOG_LEVEL:-INFO}"
export PATRONI_SCOPE POSTGRES_USER REPLICATION_PASSWORD REWIND_PASSWORD PATRONI_LOG_LEVEL

# ==============================================================================
# 1. 目录与权限（挂载卷初始为 root 属主）
# ==============================================================================
prepare_dirs() {
    mkdir -p "${PGDATA}" "${PGHOME}/logs" "${PGHOME}/archive" \
             "${PGHOME}/run" "${PGHOME}/conf.d" /var/run/postgresql
    [ "${ETCD_EMBEDDED}" = "true" ] && mkdir -p "${ETCD_DATA_DIR}"
    # 挂载卷初始为 root 属主：仅对属主不是 postgres(26) 的目录递归修正，
    # 已有数据目录（文件本身由 postgres 创建）无需重复递归，避免大目录启动慢
    local d
    chown postgres:postgres /data
    local dirs=("${PGHOME}" "${PGDATA}" "${PGHOME}/logs" "${PGHOME}/archive" \
                "${PGHOME}/run" "${PGHOME}/conf.d" /var/run/postgresql)
    [ "${ETCD_EMBEDDED}" = "true" ] && dirs+=("${ETCD_DATA_DIR}")
    for d in "${dirs[@]}"; do
        if [ "$(stat -c %u "${d}")" != "26" ]; then
            chown -R postgres:postgres "${d}"
        fi
    done
    chmod 700 "${PGDATA}"
    # etcd 建议数据目录仅属主可访问（否则启动日志会告警权限过宽）
    [ "${ETCD_EMBEDDED}" = "true" ] && chmod 700 "${ETCD_DATA_DIR}"
    log "数据目录就绪: PGDATA=${PGDATA} ETCD_DATA_DIR=${ETCD_DATA_DIR}"
}

# ==============================================================================
# 2. 启动 etcd（集群 DCS）
#    首次引导需 state=new，数据目录已初始化则必须 state=existing，
#    两者不匹配时 etcd 会直接 fatal 退出（容器反复重启）。这里主备两种 state 自动重试。
# ==============================================================================
ETCD_PID=""

try_start_etcd() {
    local state="$1"
    log "启动 etcd: name=${ETCD_NAME} state=${state}（数据目录$( [ -d "${ETCD_DATA_DIR}/member" ] && echo 已存在 || echo 为空)）"
    # etcd 3.5 会拒绝"环境变量与命令行参数同时设置"的项（ETCD_* 与 --flag 冲突），
    # 这里先清掉所有 ETCD_* 环境变量，统一由下面的命令行参数控制
    local clean_env=() v
    for v in $(compgen -e | grep -E '^ETCD_' || true); do
        clean_env+=(-u "$v")
    done
    gosu postgres env "${clean_env[@]}" etcd \
        --name "${ETCD_NAME}" \
        --data-dir "${ETCD_DATA_DIR}" \
        --listen-peer-urls "${ETCD_LISTEN_PEER_URLS:-http://0.0.0.0:2380}" \
        --listen-client-urls "${ETCD_LISTEN_CLIENT_URLS:-http://0.0.0.0:2379}" \
        --advertise-client-urls "${ETCD_ADVERTISE_CLIENT_URLS}" \
        --initial-advertise-peer-urls "${ETCD_INITIAL_ADVERTISE_PEER_URLS}" \
        --initial-cluster "${ETCD_INITIAL_CLUSTER}" \
        --initial-cluster-token "${ETCD_INITIAL_CLUSTER_TOKEN}" \
        --initial-cluster-state "${state}" \
        --quota-backend-bytes "${ETCD_QUOTA_BACKEND_BYTES}" \
        --auto-compaction-mode periodic \
        --auto-compaction-retention 1h &
    ETCD_PID=$!
}

# 等待 etcd 客户端端口就绪；超时或进程退出返回非 0（不直接退出，交由调用方切换 state 重试）
wait_etcd() {
    local i
    for i in $(seq 1 30); do
        if (exec 3<>/dev/tcp/127.0.0.1/2379) 2>/dev/null; then
            exec 3>&- 2>/dev/null || true
            log "etcd 客户端端口已就绪（约 $((i * 2))s）"
            etcdctl --endpoints="http://127.0.0.1:2379" --command-timeout=3s endpoint health || true
            return 0
        fi
        kill -0 "${ETCD_PID}" 2>/dev/null || return 1
        sleep 2
    done
    return 1
}

stop_etcd_quietly() {
    if [ -n "${ETCD_PID}" ] && kill -0 "${ETCD_PID}" 2>/dev/null; then
        kill "${ETCD_PID}" 2>/dev/null || true
        wait "${ETCD_PID}" 2>/dev/null || true
        sleep 1
    fi
    ETCD_PID=""
}

start_etcd() {
    # 显式指定 ETCD_INITIAL_CLUSTER_STATE 时只尝试该值（使用者自负其责）
    local primary fallback
    if [ -n "${ETCD_INITIAL_CLUSTER_STATE:-}" ]; then
        primary="${ETCD_INITIAL_CLUSTER_STATE}"
        fallback="${ETCD_INITIAL_CLUSTER_STATE}"
    elif [ -d "${ETCD_DATA_DIR}/member" ]; then
        primary="existing"
        fallback="new"
    else
        primary="new"
        fallback="existing"
    fi

    try_start_etcd "${primary}"
    if wait_etcd; then
        return 0
    fi

    log "WARNING: etcd 以 state=${primary} 启动失败，改用 state=${fallback} 重试"
    stop_etcd_quietly
    try_start_etcd "${fallback}"
    if wait_etcd; then
        log "etcd 已通过 state=${fallback} 启动成功"
        return 0
    fi

    log "ERROR: etcd 在两种引导状态下均启动失败，请检查上方 etcd 日志"
    exit 1
}

# ==============================================================================
# 3. 渲染 Patroni 配置（模板占位符 + 自动调优参数）
# ==============================================================================
render_patroni_config() {
    log "渲染 Patroni 配置: ${TEMPLATE} -> ${RENDERED}"
    # 目标目录由 root 独占（避免重启时覆盖上轮由 postgres 拥有的文件失败）
    mkdir -p "$(dirname "${RENDERED}")"
    rm -f "${RENDERED}"
    python3 /usr/local/bin/render-patroni-config.py \
        --template "${TEMPLATE}" --output "${RENDERED}"
    chown postgres:postgres "${RENDERED}"
    chmod 640 "${RENDERED}"
}

# ==============================================================================
# 主流程
# ==============================================================================
prepare_dirs
if [ "${ETCD_EMBEDDED}" = "true" ]; then
    start_etcd
else
    log "ETCD_EMBEDDED=false，使用外部 etcd: ${ETCD_HOSTS}（本容器不启动 etcd）"
fi
render_patroni_config

log "启动 Patroni（${PATRONI_NAME}），可用 patronictl -c ${RENDERED} list 查看集群状态"
exec gosu postgres /opt/patroni/bin/patroni "${RENDERED}"
