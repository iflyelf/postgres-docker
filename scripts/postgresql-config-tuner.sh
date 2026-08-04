#!/usr/bin/env bash
#=================================================
# PostgreSQL 配置动态调优脚本
# 功能：根据 CPU/内存限制自动计算 PostgreSQL 参数
# 参考生产 postgresql.base.conf 的计算公式：
#   shared_buffers      = 内存 * 25%
#   effective_cache_size = 内存 * 75%
#   maintenance_work_mem = 内存 * 5%（上限 2GB）
#   work_mem            = (内存 * 25%) / max_connections / 并发因子
#
# CPU/内存来源（优先级从高到低）：
#   1. 命令行/环境变量手动指定：PG_MEMORY_LIMIT / PG_CPU_LIMIT（支持 8Gi/4/500m 等 K8s 格式）
#   2. 自动探测容器 cgroup 限制（v2 优先，回退 v1）
#   3. 回退宿主机 /proc/meminfo 和 nproc
#
# 输出：可被 Patroni dynamicConfiguration 或 postgresql.conf 使用的参数
#
# 用法：
#   postgresql-config-tuner.sh [conf|--patroni]          # 自动探测
#   PG_MEMORY_LIMIT=8Gi PG_CPU_LIMIT=4 postgresql-config-tuner.sh --patroni  # 手动指定
#=================================================

set -euo pipefail

# ==============================================================================
# 0. K8s 资源格式解析（8Gi/4096Mi/500m/4 → 字节 / 核数）
# ==============================================================================
# K8s 内存格式 → 字节
parse_memory_to_bytes() {
    local s="$1"
    case "$s" in
        *Ki) echo "$(( ${s%Ki} * 1024 ))" ;;
        *Mi) echo "$(( ${s%Mi} * 1024 * 1024 ))" ;;
        *Gi) echo "$(( ${s%Gi} * 1024 * 1024 * 1024 ))" ;;
        *Ti) echo "$(( ${s%Ti} * 1024 * 1024 * 1024 * 1024 ))" ;;
        *K)  echo "$(( ${s%K} * 1000 ))" ;;
        *M)  echo "$(( ${s%M} * 1000 * 1000 ))" ;;
        *G)  echo "$(( ${s%G} * 1000 * 1000 * 1000 ))" ;;
        *T)  echo "$(( ${s%T} * 1000 * 1000 * 1000 * 1000 ))" ;;
        *)   echo "$s" ;;  # 纯字节
    esac
}

# K8s CPU 格式 → 核数（向上取整，至少 1）
parse_cpu_to_cores() {
    local s="$1"
    if [[ "$s" == *m ]]; then
        # 毫核，向上取整
        local milli="${s%m}"
        echo "$(( (milli + 999) / 1000 ))"
    else
        # 可能是浮点(如 2.5)，取整数部分，至少 1
        local intpart="${s%%.*}"
        [ -z "$intpart" ] && intpart=0
        [ "$intpart" -lt 1 ] && intpart=1
        echo "$intpart"
    fi
}

# ==============================================================================
# 1. 探测容器可用内存（字节）
#    优先 cgroup v2，其次 cgroup v1，最后回退到宿主机 /proc/meminfo
# ==============================================================================
detect_memory_bytes() {
    local mem_bytes=""

    # cgroup v2
    if [ -f /sys/fs/cgroup/memory.max ]; then
        local v
        v="$(cat /sys/fs/cgroup/memory.max)"
        if [ "$v" != "max" ]; then
            mem_bytes="$v"
        fi
    fi

    # cgroup v1
    if [ -z "$mem_bytes" ] && [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        local v
        v="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
        # cgroup v1 无限制时是一个极大值，需过滤
        if [ "$v" -lt 9223372036854770000 ]; then
            mem_bytes="$v"
        fi
    fi

    # 回退：宿主机物理内存
    if [ -z "$mem_bytes" ]; then
        local kb
        kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
        mem_bytes="$((kb * 1024))"
    fi

    echo "$mem_bytes"
}

# ==============================================================================
# 2. 探测容器可用 CPU 核数
#    优先 cgroup v2 cpu.max，其次 cgroup v1，最后 nproc
# ==============================================================================
detect_cpu_count() {
    local cpus=""

    # cgroup v2: "quota period" 或 "max period"
    if [ -f /sys/fs/cgroup/cpu.max ]; then
        local quota period
        quota="$(awk '{print $1}' /sys/fs/cgroup/cpu.max)"
        period="$(awk '{print $2}' /sys/fs/cgroup/cpu.max)"
        if [ "$quota" != "max" ] && [ "$period" -gt 0 ]; then
            cpus="$(( (quota + period - 1) / period ))"
        fi
    fi

    # cgroup v1
    if [ -z "$cpus" ] && [ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
        local quota period
        quota="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)"
        period="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)"
        if [ "$quota" -gt 0 ] && [ "$period" -gt 0 ]; then
            cpus="$(( (quota + period - 1) / period ))"
        fi
    fi

    # 回退：物理核数
    if [ -z "$cpus" ] || [ "$cpus" -lt 1 ]; then
        cpus="$(nproc)"
    fi

    echo "$cpus"
}

# ==============================================================================
# 3. 计算 PostgreSQL 参数
# ==============================================================================
# 内存：优先手动指定 PG_MEMORY_LIMIT，否则自动探测
if [ -n "${PG_MEMORY_LIMIT:-}" ]; then
    MEM_BYTES="$(parse_memory_to_bytes "${PG_MEMORY_LIMIT}")"
    MEM_SOURCE="手动指定 ${PG_MEMORY_LIMIT}"
else
    MEM_BYTES="$(detect_memory_bytes)"
    MEM_SOURCE="自动探测"
fi

# CPU：优先手动指定 PG_CPU_LIMIT，否则自动探测
if [ -n "${PG_CPU_LIMIT:-}" ]; then
    CPU_COUNT="$(parse_cpu_to_cores "${PG_CPU_LIMIT}")"
    CPU_SOURCE="手动指定 ${PG_CPU_LIMIT}"
else
    CPU_COUNT="$(detect_cpu_count)"
    CPU_SOURCE="自动探测"
fi

MEM_MB="$((MEM_BYTES / 1024 / 1024))"

# max_connections：沿用生产配置
MAX_CONNECTIONS="${PG_MAX_CONNECTIONS:-10000}"

# shared_buffers = 内存 25%
SHARED_BUFFERS_MB="$((MEM_MB * 25 / 100))"

# effective_cache_size = 内存 75%
EFFECTIVE_CACHE_SIZE_MB="$((MEM_MB * 75 / 100))"

# maintenance_work_mem = 内存 5%，上限 2048MB
MAINTENANCE_WORK_MEM_MB="$((MEM_MB * 5 / 100))"
if [ "$MAINTENANCE_WORK_MEM_MB" -gt 2048 ]; then
    MAINTENANCE_WORK_MEM_MB=2048
fi

# work_mem：((内存25%) / (max_connections * 并发因子))，最小 4MB
# 并发因子取 4（估计并行操作占比），避免 work_mem 过大导致 OOM
WORK_MEM_KB="$(( (MEM_MB * 25 / 100) * 1024 / (MAX_CONNECTIONS * 4) ))"
if [ "$WORK_MEM_KB" -lt 4096 ]; then
    WORK_MEM_KB=4096
fi

# wal_buffers = shared_buffers 的 1/32，上限 16MB
WAL_BUFFERS_MB="$((SHARED_BUFFERS_MB / 32))"
if [ "$WAL_BUFFERS_MB" -gt 16 ]; then
    WAL_BUFFERS_MB=16
fi
if [ "$WAL_BUFFERS_MB" -lt 1 ]; then
    WAL_BUFFERS_MB=1
fi

# 并行 worker 相关（基于 CPU 核数）
MAX_WORKER_PROCESSES="$CPU_COUNT"
if [ "$MAX_WORKER_PROCESSES" -lt 8 ]; then
    MAX_WORKER_PROCESSES=8
fi
MAX_PARALLEL_WORKERS="$CPU_COUNT"
MAX_PARALLEL_WORKERS_PER_GATHER="$((CPU_COUNT / 2))"
if [ "$MAX_PARALLEL_WORKERS_PER_GATHER" -lt 2 ]; then
    MAX_PARALLEL_WORKERS_PER_GATHER=2
fi
MAX_PARALLEL_MAINTENANCE_WORKERS="$((CPU_COUNT / 2))"
if [ "$MAX_PARALLEL_MAINTENANCE_WORKERS" -lt 2 ]; then
    MAX_PARALLEL_MAINTENANCE_WORKERS=2
fi

# TimescaleDB 后台 worker（建议 = CPU 核数 + 1，上限 16）
TS_MAX_BACKGROUND_WORKERS="$((CPU_COUNT + 1))"
if [ "$TS_MAX_BACKGROUND_WORKERS" -gt 16 ]; then
    TS_MAX_BACKGROUND_WORKERS=16
fi

# max_worker_processes 需 >= 并行 worker + TimescaleDB worker，做汇总修正
NEEDED_WORKERS="$((MAX_PARALLEL_WORKERS + TS_MAX_BACKGROUND_WORKERS + 4))"
if [ "$MAX_WORKER_PROCESSES" -lt "$NEEDED_WORKERS" ]; then
    MAX_WORKER_PROCESSES="$NEEDED_WORKERS"
fi

# ==============================================================================
# 4. 输出（默认 postgresql.conf 片段格式；--patroni 输出 YAML 片段）
# ==============================================================================
FORMAT="${1:-conf}"

if [ "$FORMAT" = "--patroni" ] || [ "$FORMAT" = "yaml" ]; then
    cat <<YAML
# 由 postgresql-config-tuner.sh 自动生成（内存 ${MEM_MB}MB[${MEM_SOURCE}] / CPU ${CPU_COUNT} 核[${CPU_SOURCE}]）
        shared_buffers: ${SHARED_BUFFERS_MB}MB
        effective_cache_size: ${EFFECTIVE_CACHE_SIZE_MB}MB
        maintenance_work_mem: ${MAINTENANCE_WORK_MEM_MB}MB
        work_mem: ${WORK_MEM_KB}kB
        wal_buffers: ${WAL_BUFFERS_MB}MB
        max_worker_processes: ${MAX_WORKER_PROCESSES}
        max_parallel_workers: ${MAX_PARALLEL_WORKERS}
        max_parallel_workers_per_gather: ${MAX_PARALLEL_WORKERS_PER_GATHER}
        max_parallel_maintenance_workers: ${MAX_PARALLEL_MAINTENANCE_WORKERS}
        timescaledb.max_background_workers: ${TS_MAX_BACKGROUND_WORKERS}
YAML
else
    cat <<CONF
# 由 postgresql-config-tuner.sh 自动生成（内存 ${MEM_MB}MB[${MEM_SOURCE}] / CPU ${CPU_COUNT} 核[${CPU_SOURCE}]）
shared_buffers = '${SHARED_BUFFERS_MB}MB'
effective_cache_size = '${EFFECTIVE_CACHE_SIZE_MB}MB'
maintenance_work_mem = '${MAINTENANCE_WORK_MEM_MB}MB'
work_mem = '${WORK_MEM_KB}kB'
wal_buffers = '${WAL_BUFFERS_MB}MB'
max_worker_processes = ${MAX_WORKER_PROCESSES}
max_parallel_workers = ${MAX_PARALLEL_WORKERS}
max_parallel_workers_per_gather = ${MAX_PARALLEL_WORKERS_PER_GATHER}
max_parallel_maintenance_workers = ${MAX_PARALLEL_MAINTENANCE_WORKERS}
timescaledb.max_background_workers = ${TS_MAX_BACKGROUND_WORKERS}
CONF
fi
