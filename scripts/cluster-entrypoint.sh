#!/usr/bin/env bash
# ==============================================================================
# 集群模式容器入口（3 节点：etcd + Patroni + PostgreSQL 同容器）
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
PGHOME="${PGHOME:-/data/postgres}"
PGDATA="${PGDATA:-${PGHOME}/data}"
ETCD_DATA_DIR="${ETCD_DATA_DIR:-/data/etcd}"
ETCD_NAME="${ETCD_NAME:-pg1}"
ETCD_INITIAL_CLUSTER_STATE="${ETCD_INITIAL_CLUSTER_STATE:-new}"
ETCD_INITIAL_CLUSTER_TOKEN="${ETCD_INITIAL_CLUSTER_TOKEN:-postgres-cluster}"
ETCD_QUOTA_BACKEND_BYTES="${ETCD_QUOTA_BACKEND_BYTES:-4294967296}"
TEMPLATE="${PATRONI_TEMPLATE:-/etc/patroni/patroni.yml.tmpl}"
RENDERED="${PATRONI_CONFIG:-/tmp/patroni.yml}"
export PG_MAJOR

: "${PATRONI_NAME:?请设置 PATRONI_NAME（如 pg1）}"
: "${PATRONI_CONNECT_HOST:?请设置 PATRONI_CONNECT_HOST（如 pg1）}"
: "${ETCD_HOSTS:?请设置 ETCD_HOSTS（如 pg1:2379,pg2:2379,pg3:2379）}"
: "${ETCD_INITIAL_CLUSTER:?请设置 ETCD_INITIAL_CLUSTER}"
: "${ETCD_INITIAL_ADVERTISE_PEER_URLS:?请设置 ETCD_INITIAL_ADVERTISE_PEER_URLS}"
: "${ETCD_ADVERTISE_CLIENT_URLS:?请设置 ETCD_ADVERTISE_CLIENT_URLS}"
: "${POSTGRES_PASSWORD:?请设置 POSTGRES_PASSWORD}"

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
    mkdir -p "${ETCD_DATA_DIR}" "${PGDATA}" "${PGHOME}/logs" "${PGHOME}/archive" \
             "${PGHOME}/run" "${PGHOME}/conf.d" /var/run/postgresql
    # 挂载卷初始为 root 属主：仅对属主不是 postgres(26) 的目录递归修正，
    # 已有数据目录（文件本身由 postgres 创建）无需重复递归，避免大目录启动慢
    local d
    chown postgres:postgres /data
    for d in "${ETCD_DATA_DIR}" "${PGHOME}" "${PGDATA}" "${PGHOME}/logs" \
             "${PGHOME}/archive" "${PGHOME}/run" "${PGHOME}/conf.d" /var/run/postgresql; do
        if [ "$(stat -c %u "${d}")" != "26" ]; then
            chown -R postgres:postgres "${d}"
        fi
    done
    chmod 700 "${PGDATA}"
    # etcd 建议数据目录仅属主可访问（否则启动日志会告警权限过宽）
    chmod 700 "${ETCD_DATA_DIR}"
    log "数据目录就绪: PGDATA=${PGDATA} ETCD_DATA_DIR=${ETCD_DATA_DIR}"
}

# ==============================================================================
# 2. 启动 etcd（集群 DCS）
# ==============================================================================
start_etcd() {
    log "启动 etcd: name=${ETCD_NAME} state=${ETCD_INITIAL_CLUSTER_STATE}"
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
        --initial-cluster-state "${ETCD_INITIAL_CLUSTER_STATE}" \
        --quota-backend-bytes "${ETCD_QUOTA_BACKEND_BYTES}" \
        --auto-compaction-mode periodic \
        --auto-compaction-retention 1h &
    ETCD_PID=$!
    log "etcd 已启动（pid ${ETCD_PID}），等待客户端端口 2379 就绪..."
}

wait_etcd() {
    local i
    for i in $(seq 1 90); do
        if (exec 3<>/dev/tcp/127.0.0.1/2379) 2>/dev/null; then
            exec 3>&- 2>/dev/null || true
            log "etcd 客户端端口已就绪（等待 ${i} 次 / 约 $((i * 2))s）"
            # 集群成员可能尚未全部加入，健康检查仅作日志参考
            etcdctl --endpoints="http://127.0.0.1:2379" --command-timeout=3s endpoint health || true
            return 0
        fi
        if ! kill -0 "${ETCD_PID}" 2>/dev/null; then
            log "ERROR: etcd 进程已退出，请检查上方 etcd 日志"
            exit 1
        fi
        sleep 2
    done
    log "ERROR: etcd 在 180s 内未就绪"
    exit 1
}

# ==============================================================================
# 3. 渲染 Patroni 配置（模板占位符 + 自动调优参数）
# ==============================================================================
render_patroni_config() {
    log "渲染 Patroni 配置: ${TEMPLATE} -> ${RENDERED}"
    python3 /usr/local/bin/render-patroni-config.py \
        --template "${TEMPLATE}" --output "${RENDERED}"
    chown postgres:postgres "${RENDERED}"
    chmod 640 "${RENDERED}"
}

# ==============================================================================
# 主流程
# ==============================================================================
prepare_dirs
start_etcd
wait_etcd
render_patroni_config

log "启动 Patroni（${PATRONI_NAME}），可用 patronictl -c ${RENDERED} list 查看集群状态"
exec gosu postgres /opt/patroni/bin/patroni "${RENDERED}"
