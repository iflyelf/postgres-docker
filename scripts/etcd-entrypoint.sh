#!/usr/bin/env bash
# ==============================================================================
# 独立 etcd 容器入口（3 节点集群的 DCS）
#
# 与 PostgreSQL 容器解耦：节点重启不会牵动 etcd，etcd 持久化在独立数据卷
# 首次启动用 --initial-cluster-state=new 引导集群，之后自动切换为 existing
#
# 环境变量（见 docker-compose.cluster.yml）：
#   ETCD_NAME / ETCD_INITIAL_CLUSTER / ETCD_INITIAL_ADVERTISE_PEER_URLS
#   ETCD_ADVERTISE_CLIENT_URLS / ETCD_INITIAL_CLUSTER_TOKEN
# 可选：
#   ETCD_DATA_DIR（默认 /etcd-data）
#   ETCD_INITIAL_CLUSTER_STATE（显式指定 new/existing，默认按数据目录自动判断）
# ==============================================================================
set -Eeuo pipefail

log() { echo ">>> [etcd-entrypoint] $*"; }

: "${ETCD_NAME:?请设置 ETCD_NAME}"
: "${ETCD_INITIAL_CLUSTER:?请设置 ETCD_INITIAL_CLUSTER}"
: "${ETCD_INITIAL_ADVERTISE_PEER_URLS:?请设置 ETCD_INITIAL_ADVERTISE_PEER_URLS}"
: "${ETCD_ADVERTISE_CLIENT_URLS:?请设置 ETCD_ADVERTISE_CLIENT_URLS}"

ETCD_DATA_DIR="${ETCD_DATA_DIR:-/etcd-data}"
ETCD_INITIAL_CLUSTER_TOKEN="${ETCD_INITIAL_CLUSTER_TOKEN:-postgres-cluster}"
ETCD_QUOTA_BACKEND_BYTES="${ETCD_QUOTA_BACKEND_BYTES:-4294967296}"

# 数据目录可能是宿主机挂载的 root 属主目录，先修正权限再降权运行
mkdir -p "${ETCD_DATA_DIR}"
chown -R postgres:postgres "${ETCD_DATA_DIR}"
chmod 700 "${ETCD_DATA_DIR}"

# 首次引导用 new，数据目录已初始化则用 existing（显式指定时以其为准）
if [ -n "${ETCD_INITIAL_CLUSTER_STATE:-}" ]; then
    STATE="${ETCD_INITIAL_CLUSTER_STATE}"
elif [ -d "${ETCD_DATA_DIR}/member" ]; then
    STATE="existing"
else
    STATE="new"
fi

log "启动 etcd: name=${ETCD_NAME} state=${STATE} data-dir=${ETCD_DATA_DIR}"

# etcd 3.5 拒绝"环境变量与命令行参数同时设置"，先清空所有 ETCD_* 环境变量
clean_env=()
for v in $(compgen -e | grep -E '^ETCD_' || true); do
    clean_env+=(-u "$v")
done

exec gosu postgres env "${clean_env[@]}" etcd \
    --name "${ETCD_NAME}" \
    --data-dir "${ETCD_DATA_DIR}" \
    --listen-peer-urls "${ETCD_LISTEN_PEER_URLS:-http://0.0.0.0:2380}" \
    --listen-client-urls "${ETCD_LISTEN_CLIENT_URLS:-http://0.0.0.0:2379}" \
    --advertise-client-urls "${ETCD_ADVERTISE_CLIENT_URLS}" \
    --initial-advertise-peer-urls "${ETCD_INITIAL_ADVERTISE_PEER_URLS}" \
    --initial-cluster "${ETCD_INITIAL_CLUSTER}" \
    --initial-cluster-token "${ETCD_INITIAL_CLUSTER_TOKEN}" \
    --initial-cluster-state "${STATE}" \
    --quota-backend-bytes "${ETCD_QUOTA_BACKEND_BYTES}" \
    --auto-compaction-mode periodic \
    --auto-compaction-retention 1h
