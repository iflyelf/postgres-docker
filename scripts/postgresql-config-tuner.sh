#!/usr/bin/env bash
#=================================================
# PostgreSQL 配置动态调优脚本
# 功能：根据容器实际 CPU/内存限制自动计算 PostgreSQL 参数
# 参考生产 postgresql.base.conf 的计算公式：
#   shared_buffers      = 内存 * 25%
#   effective_cache_size = 内存 * 75%
#   maintenance_work_mem = 内存 * 5%（上限 2GB）
#   work_mem            = (内存 * 25%) / max_connections / 并发因子
# 输出：可被 Patroni dynamicConfiguration 或 postgresql.conf 使用的参数
#=================================================

set -euo pipefail

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
MEM_BYTES="$(detect_memory_bytes)"
CPU_COUNT="$(detect_cpu_count)"

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
# 由 postgresql-config-tuner.sh 自动生成（内存 ${MEM_MB}MB / CPU ${CPU_COUNT} 核）
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
# 由 postgresql-config-tuner.sh 自动生成（内存 ${MEM_MB}MB / CPU ${CPU_COUNT} 核）
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
