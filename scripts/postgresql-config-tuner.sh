#!/usr/bin/env bash
#=================================================
# https://github.com/iflyelf/postgres-docker
# PostgreSQL 配置动态调优脚本
#
# 功能：按容器 CPU / 内存限制自动计算 PostgreSQL 参数，并生成带中文注释的配置。
#
# 资源来源（优先级从高到低）：
#   1. 环境变量手动指定：PG_MEMORY_LIMIT / PG_CPU_LIMIT（支持 8Gi/4/500m 等 K8s 格式）
#   2. 自动探测容器 cgroup 限制（v2 优先，回退 v1）
#   3. 回退宿主机 /proc/meminfo 与 nproc
#
# 用法：
#   postgresql-config-tuner.sh [conf|yaml|--patroni]
#     conf        输出 postgresql.conf 片段（默认，每项参数带中文注释与公式）
#     yaml        输出 Patroni dynamicConfiguration.postgresql.parameters 片段
#     --patroni   同 yaml
#   postgresql-config-tuner.sh summary     # 仅输出资源探测与关键参数摘要
#
# 可覆盖的环境变量：
#   PG_MEMORY_LIMIT        内存上限（如 8Gi / 8192Mi / 8589934592）
#   PG_CPU_LIMIT           CPU 上限（如 4 / 2.5 / 500m）
#   PG_MAX_CONNECTIONS     直接指定 max_connections（默认按内存/CPU 自动计算）
#=================================================

set -euo pipefail

# ==============================================================================
# 0. K8s 资源格式解析（8Gi/4096Mi/500m/4 → 字节 / 核数）
# ==============================================================================
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
        *)   echo "$s" ;;
    esac
}

parse_cpu_to_cores() {
    local s="$1"
    if [[ "$s" == *m ]]; then
        local milli="${s%m}"
        echo "$(( (milli + 999) / 1000 ))"
    else
        local intpart="${s%%.*}"
        [ -z "$intpart" ] && intpart=0
        [ "$intpart" -lt 1 ] && intpart=1
        echo "$intpart"
    fi
}

# clamp 值 下限 上限：把 $1 限制在 [$2, $3]
clamp() {
    local v="$1" lo="$2" hi="$3"
    [ "$v" -lt "$lo" ] && v="$lo"
    [ "$v" -gt "$hi" ] && v="$hi"
    echo "$v"
}

# ==============================================================================
# 1. 探测容器可用内存（字节）
#    优先 cgroup v2，其次 cgroup v1，最后回退宿主机 /proc/meminfo
# ==============================================================================
detect_memory_bytes() {
    local mem_bytes=""

    if [ -f /sys/fs/cgroup/memory.max ]; then
        local v
        v="$(cat /sys/fs/cgroup/memory.max)"
        [ "$v" != "max" ] && mem_bytes="$v"
    fi

    if [ -z "$mem_bytes" ] && [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        local v
        v="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
        # cgroup v1 无限制时是一个极大值，需过滤
        if [ "$v" -lt 9223372036854770000 ]; then
            mem_bytes="$v"
        fi
    fi

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

    if [ -f /sys/fs/cgroup/cpu.max ]; then
        local quota period
        quota="$(awk '{print $1}' /sys/fs/cgroup/cpu.max)"
        period="$(awk '{print $2}' /sys/fs/cgroup/cpu.max)"
        if [ "$quota" != "max" ] && [ "$period" -gt 0 ]; then
            cpus="$(( (quota + period - 1) / period ))"
        fi
    fi

    if [ -z "$cpus" ] && [ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
        local quota period
        quota="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)"
        period="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)"
        if [ "$quota" -gt 0 ] && [ "$period" -gt 0 ]; then
            cpus="$(( (quota + period - 1) / period ))"
        fi
    fi

    if [ -z "$cpus" ] || [ "$cpus" -lt 1 ]; then
        cpus="$(nproc)"
    fi

    echo "$cpus"
}

# ==============================================================================
# 3. 采集资源（内存 / CPU）
# ==============================================================================
if [ -n "${PG_MEMORY_LIMIT:-}" ]; then
    MEM_BYTES="$(parse_memory_to_bytes "${PG_MEMORY_LIMIT}")"
    MEM_SOURCE="手动指定 PG_MEMORY_LIMIT=${PG_MEMORY_LIMIT}"
else
    MEM_BYTES="$(detect_memory_bytes)"
    MEM_SOURCE="自动探测(cgroup/宿主机)"
fi

if [ -n "${PG_CPU_LIMIT:-}" ]; then
    CPU_COUNT="$(parse_cpu_to_cores "${PG_CPU_LIMIT}")"
    CPU_SOURCE="手动指定 PG_CPU_LIMIT=${PG_CPU_LIMIT}"
else
    CPU_COUNT="$(detect_cpu_count)"
    CPU_SOURCE="自动探测(cgroup/宿主机)"
fi

MEM_MB="$((MEM_BYTES / 1024 / 1024))"
[ "$MEM_MB" -lt 256 ] && MEM_MB=256      # 兜底：异常探测值按 256MB 处理
[ "$CPU_COUNT" -lt 1 ] && CPU_COUNT=1

# ==============================================================================
# 4. 计算参数
#    公式来源：PostgreSQL 官方 wiki(https://wiki.postgresql.org/wiki/Tuning_Your_PostgreSQL_Server)
#              + TimescaleDB 官方调优建议
#    原则：内存型参数按内存比例，并发型参数按连接数与 CPU 核数推导
# ==============================================================================

# ---------- 连接数 ----------
# max_connections 自动计算：
#   内存侧上限 = 内存(MB) / 16        （每 16MB 内存支撑 1 个连接，约 8GB→512）
#   CPU 侧上限 = CPU 核数 × 150 + 100 （每核约 150 个活跃连接，另加 100 个空闲连接）
#   取两者较小值，限制在 [100, 5000]；使用连接池(pgbouncer)时可手动调小
if [ -n "${PG_MAX_CONNECTIONS:-}" ]; then
    CONN_BY_MEM="$((MEM_MB / 16))"
    CONN_BY_CPU="$((CPU_COUNT * 150 + 100))"
    MAX_CONNECTIONS="$PG_MAX_CONNECTIONS"
    CONN_SOURCE="手动指定 PG_MAX_CONNECTIONS=${PG_MAX_CONNECTIONS}（自动计算值 min(${CONN_BY_MEM}, ${CONN_BY_CPU}) 被覆盖）"
else
    CONN_BY_MEM="$((MEM_MB / 16))"
    CONN_BY_CPU="$((CPU_COUNT * 150 + 100))"
    MAX_CONNECTIONS="$CONN_BY_MEM"
    [ "$CONN_BY_CPU" -lt "$MAX_CONNECTIONS" ] && MAX_CONNECTIONS="$CONN_BY_CPU"
    MAX_CONNECTIONS="$(clamp "$MAX_CONNECTIONS" 100 5000)"
    CONN_SOURCE="自动计算(min(内存/16, CPU×150+100), 限制 100~5000)"
fi

# 超级用户保留连接：约 1%，限制 3~20
SUPERUSER_RESERVED="$((MAX_CONNECTIONS / 100))"
SUPERUSER_RESERVED="$(clamp "$SUPERUSER_RESERVED" 3 20)"

# ---------- 内存型参数 ----------
# shared_buffers = 内存 25%（PG 官方建议 25%，限制 128MB~64GB）
SHARED_BUFFERS_MB="$(clamp "$((MEM_MB * 25 / 100))" 128 65536)"

# effective_cache_size = 内存 75%（供优化器估算，不实际占用内存）
EFFECTIVE_CACHE_SIZE_MB="$((MEM_MB * 75 / 100))"

# maintenance_work_mem = 内存 5%（VACUUM/CREATE INDEX 用，限制 64MB~2GB）
MAINTENANCE_WORK_MEM_MB="$(clamp "$((MEM_MB * 5 / 100))" 64 2048)"

# work_mem = (内存 25%) / (max_connections × 4)，限制 4MB~256MB
#   并发因子 4：估计同时有 4 个排序/哈希操作复用同一连接内存预算
WORK_MEM_MB="$((MEM_MB * 25 / 100 / (MAX_CONNECTIONS * 4)))"
WORK_MEM_MB="$(clamp "$WORK_MEM_MB" 4 256)"

# temp_buffers = shared_buffers / 128，限制 8MB~128MB（每会话临时表缓存）
TEMP_BUFFERS_MB="$(clamp "$((SHARED_BUFFERS_MB / 128))" 8 128)"

# ---------- WAL 型参数 ----------
# wal_buffers = shared_buffers / 32，限制 1MB~16MB（-1 表示自动，这里显式计算便于观察）
WAL_BUFFERS_MB="$(clamp "$((SHARED_BUFFERS_MB / 32))" 1 16)"

# min_wal_size = shared_buffers / 4，限制 512MB~4GB（保证检查点间隔内不频繁回收 WAL）
MIN_WAL_MB="$(clamp "$((SHARED_BUFFERS_MB / 4))" 512 4096)"

# max_wal_size = shared_buffers × 2，限制 2GB~32GB（越大检查点越少，写放大越低）
MAX_WAL_MB="$(clamp "$((SHARED_BUFFERS_MB * 2))" 2048 32768)"

# wal_keep_size = max_wal_size / 2，限制 512MB~8GB（为主从复制保留 WAL）
WAL_KEEP_MB="$(clamp "$((MAX_WAL_MB / 2))" 512 8192)"

# ---------- 复制型参数（按 CPU 推导） ----------
MAX_WAL_SENDERS="$(clamp "$((CPU_COUNT * 2))" 10 64)"
MAX_REPLICATION_SLOTS="$MAX_WAL_SENDERS"

# ---------- 并行/worker 型参数 ----------
# max_parallel_workers = CPU 核数
MAX_PARALLEL_WORKERS="$CPU_COUNT"
[ "$MAX_PARALLEL_WORKERS" -lt 2 ] && MAX_PARALLEL_WORKERS=2

# max_parallel_workers_per_gather = CPU / 2（单条查询最多并行 worker）
MAX_PARALLEL_WORKERS_PER_GATHER="$((CPU_COUNT / 2))"
[ "$MAX_PARALLEL_WORKERS_PER_GATHER" -lt 2 ] && MAX_PARALLEL_WORKERS_PER_GATHER=2

# max_parallel_maintenance_workers = CPU / 2（CREATE INDEX/VACUUM 并行）
MAX_PARALLEL_MAINTENANCE_WORKERS="$((CPU_COUNT / 2))"
[ "$MAX_PARALLEL_MAINTENANCE_WORKERS" -lt 2 ] && MAX_PARALLEL_MAINTENANCE_WORKERS=2

# timescaledb.max_background_workers = CPU + 1，上限 16（TimescaleDB 后台任务）
TS_MAX_BACKGROUND_WORKERS="$(clamp "$((CPU_COUNT + 1))" 2 16)"

# max_worker_processes 必须 >= 并行 worker + TimescaleDB worker + 系统预留 4
NEEDED_WORKERS="$((MAX_PARALLEL_WORKERS + TS_MAX_BACKGROUND_WORKERS + 4))"
MAX_WORKER_PROCESSES="$CPU_COUNT"
[ "$MAX_WORKER_PROCESSES" -lt 8 ] && MAX_WORKER_PROCESSES=8
[ "$MAX_WORKER_PROCESSES" -lt "$NEEDED_WORKERS" ] && MAX_WORKER_PROCESSES="$NEEDED_WORKERS"

# ---------- autovacuum 型参数 ----------
# autovacuum_max_workers = CPU 核数，限制 3~8（并行清理表数量）
AUTOVACUUM_MAX_WORKERS="$(clamp "$CPU_COUNT" 3 8)"

# autovacuum_vacuum_cost_limit = CPU × 100，限制 200~2000（越大清理越快、IO 压力越高）
AUTOVACUUM_COST_LIMIT="$(clamp "$((CPU_COUNT * 100))" 200 2000)"

# ---------- IO 型参数（默认按 SSD 计算） ----------
# effective_io_concurrency = CPU × 8，限制 16~200（SSD 可同时下发多个 IO）
EFFECTIVE_IO_CONCURRENCY="$(clamp "$((CPU_COUNT * 8))" 16 200)"
# maintenance_io_concurrency = CPU × 4，限制 8~100（维护类操作并发 IO）
MAINTENANCE_IO_CONCURRENCY="$(clamp "$((CPU_COUNT * 4))" 8 100)"

# ---------- 锁表参数 ----------
# max_locks_per_transaction = max_connections / 32，限制 64~512
MAX_LOCKS_PER_TRANSACTION="$(clamp "$((MAX_CONNECTIONS / 32))" 64 512)"

# ==============================================================================
# 5. 生成带中文注释的配置
# ==============================================================================
FORMAT="${1:-conf}"

# 公共资源摘要行
RESOURCE_LINE="内存 ${MEM_MB}MB[${MEM_SOURCE}] / CPU ${CPU_COUNT} 核[${CPU_SOURCE}]"

# Patroni YAML 片段（Operator 会覆盖 postgresql.conf，这里仅供 dynamicConfiguration 参考）
emit_yaml() {
cat <<YAML
        # ===== 自动生成：${RESOURCE_LINE} =====
        # 连接数：${CONN_SOURCE}
        max_connections: ${MAX_CONNECTIONS}
        superuser_reserved_connections: ${SUPERUSER_RESERVED}
        # 共享缓冲区 = 内存 × 25%（${MEM_MB}MB × 25% = ${SHARED_BUFFERS_MB}MB，限制 128MB~64GB）
        shared_buffers: ${SHARED_BUFFERS_MB}MB
        # 优化器可用缓存估计 = 内存 × 75%（${MEM_MB}MB × 75% = ${EFFECTIVE_CACHE_SIZE_MB}MB，不实际占用）
        effective_cache_size: ${EFFECTIVE_CACHE_SIZE_MB}MB
        # 维护操作内存 = 内存 × 5%（${MEM_MB}MB × 5% → ${MAINTENANCE_WORK_MEM_MB}MB，限制 64MB~2GB）
        maintenance_work_mem: ${MAINTENANCE_WORK_MEM_MB}MB
        # 单次排序/哈希内存 = 内存 × 25% ÷ (连接数 × 4)（((${MEM_MB}×25%)÷(${MAX_CONNECTIONS}×4)) → ${WORK_MEM_MB}MB，限制 4MB~256MB）
        work_mem: ${WORK_MEM_MB}MB
        # 会话临时表缓存 = shared_buffers ÷ 128（${SHARED_BUFFERS_MB}÷128 → ${TEMP_BUFFERS_MB}MB，限制 8MB~128MB）
        temp_buffers: ${TEMP_BUFFERS_MB}MB
        # WAL 缓冲区 = shared_buffers ÷ 32（${SHARED_BUFFERS_MB}÷32 → ${WAL_BUFFERS_MB}MB，限制 1MB~16MB）
        wal_buffers: ${WAL_BUFFERS_MB}MB
        # 最小 WAL = shared_buffers ÷ 4（${SHARED_BUFFERS_MB}÷4 → ${MIN_WAL_MB}MB，限制 512MB~4GB）
        min_wal_size: ${MIN_WAL_MB}MB
        # 最大 WAL = shared_buffers × 2（${SHARED_BUFFERS_MB}×2 → ${MAX_WAL_MB}MB，限制 2GB~32GB，减少检查点频率）
        max_wal_size: ${MAX_WAL_MB}MB
        # 复制保留 WAL = max_wal_size ÷ 2（${MAX_WAL_MB}÷2 → ${WAL_KEEP_MB}MB，限制 512MB~8GB）
        wal_keep_size: ${WAL_KEEP_MB}MB
        # 检查点超时：TimescaleDB 建议 15min，避免频繁全量刷盘
        checkpoint_timeout: 15min
        # 检查点写入平滑度：0.9 = 在 90% 检查点间隔内均匀写入
        checkpoint_completion_target: 0.9
        # WAL 压缩：on 平衡 CPU 与 WAL 体积（PG17 可选 lz4/zstd，此处取通用 on）
        wal_compression: on
        # 并行查询 worker 数 = CPU 核数（${CPU_COUNT}）
        max_parallel_workers: ${MAX_PARALLEL_WORKERS}
        # 单查询并行 worker 上限 = CPU ÷ 2（${CPU_COUNT}÷2 → ${MAX_PARALLEL_WORKERS_PER_GATHER}）
        max_parallel_workers_per_gather: ${MAX_PARALLEL_WORKERS_PER_GATHER}
        # 并行维护 worker 上限 = CPU ÷ 2（${CPU_COUNT}÷2 → ${MAX_PARALLEL_MAINTENANCE_WORKERS}）
        max_parallel_maintenance_workers: ${MAX_PARALLEL_MAINTENANCE_WORKERS}
        # 后台 worker 总数：max(8, CPU, 并行+TimescaleDB+4) → ${MAX_WORKER_PROCESSES}
        max_worker_processes: ${MAX_WORKER_PROCESSES}
        # TimescaleDB 后台 worker = CPU + 1（${CPU_COUNT}+1 → ${TS_MAX_BACKGROUND_WORKERS}，上限 16）
        timescaledb.max_background_workers: ${TS_MAX_BACKGROUND_WORKERS}
        # 自动清理 worker = CPU 核数（限制 3~8）→ ${AUTOVACUUM_MAX_WORKERS}
        autovacuum_max_workers: ${AUTOVACUUM_MAX_WORKERS}
        # 自动清理 IO 预算 = CPU × 100（限制 200~2000）→ ${AUTOVACUUM_COST_LIMIT}
        autovacuum_vacuum_cost_limit: ${AUTOVACUUM_COST_LIMIT}
        # 自动清理轮询间隔：10s，小表也能较快回收
        autovacuum_naptime: 10s
        # 随机页读取成本：SSD 取 1.1（HDD 建议 4.0）
        random_page_cost: 1.1
        # IO 并发 = CPU × 8（限制 16~200，SSD 多队列）→ ${EFFECTIVE_IO_CONCURRENCY}
        effective_io_concurrency: ${EFFECTIVE_IO_CONCURRENCY}
        # 维护类 IO 并发 = CPU × 4（限制 8~100）→ ${MAINTENANCE_IO_CONCURRENCY}
        maintenance_io_concurrency: ${MAINTENANCE_IO_CONCURRENCY}
        # 单事务锁上限 = 连接数 ÷ 32（限制 64~512）→ ${MAX_LOCKS_PER_TRANSACTION}
        max_locks_per_transaction: ${MAX_LOCKS_PER_TRANSACTION}
        # 复制发送进程 = CPU × 2（限制 10~64）→ ${MAX_WAL_SENDERS}
        max_wal_senders: ${MAX_WAL_SENDERS}
        # 复制槽数量与发送进程一致 → ${MAX_REPLICATION_SLOTS}
        max_replication_slots: ${MAX_REPLICATION_SLOTS}
YAML
}

# postgresql.conf 片段（含中文注释，可直接被 include_dir 引入）
emit_conf() {
cat <<CONF
###############################################################################
#  PostgreSQL 自动调优配置（由 postgresql-config-tuner.sh 生成）
#  资源：${RESOURCE_LINE}
#  说明：本文件每次容器启动都会重新生成，请勿手工修改（改 Dockerfile 或脚本）
#  调优公式见 https://github.com/iflyelf/postgres-docker#cpu--内存自动调优
###############################################################################

#------------------------------------------------------------------------------
# 连接数
#------------------------------------------------------------------------------
# 连接数：${CONN_SOURCE}
#   内存侧上限 = 内存(MB) ÷ 16 = ${MEM_MB}÷16 = ${CONN_BY_MEM}
#   CPU 侧上限  = CPU × 150 + 100 = ${CPU_COUNT}×150+100 = ${CONN_BY_CPU}
#   自动取值 = clamp(min(两者), 100, 5000)，最终生效值 = ${MAX_CONNECTIONS}
#   使用 pgbouncer 等连接池时可通过 PG_MAX_CONNECTIONS 调小
max_connections = ${MAX_CONNECTIONS}

# 超级用户保留连接：max_connections ÷ 100，限制 3~20 → ${SUPERUSER_RESERVED}
superuser_reserved_connections = ${SUPERUSER_RESERVED}

#------------------------------------------------------------------------------
# 内存参数
#------------------------------------------------------------------------------
# 共享缓冲区 = 内存 × 25% = ${MEM_MB}MB × 25% = ${SHARED_BUFFERS_MB}MB（限制 128MB~64GB）
#   数据库最热数据缓存，建议为物理内存的 25%
shared_buffers = '${SHARED_BUFFERS_MB}MB'

# 优化器缓存估计 = 内存 × 75% = ${MEM_MB}MB × 75% = ${EFFECTIVE_CACHE_SIZE_MB}MB
#   仅用于代价估算，不实际占用内存（shared_buffers + OS page cache）
effective_cache_size = '${EFFECTIVE_CACHE_SIZE_MB}MB'

# 维护内存 = 内存 × 5% = ${MAINTENANCE_WORK_MEM_MB}MB（限制 64MB~2GB）
#   VACUUM / CREATE INDEX / ALTER TABLE 等维护操作单次可用内存
maintenance_work_mem = '${MAINTENANCE_WORK_MEM_MB}MB'

# 单次排序/哈希内存 = (内存 × 25%) ÷ (max_connections × 4) = ${WORK_MEM_MB}MB（限制 4MB~256MB）
#   (${MEM_MB}×25%) ÷ (${MAX_CONNECTIONS}×4) = $((MEM_MB * 25 / 100 / (MAX_CONNECTIONS * 4)))MB
#   并发因子 4 表示同时约有 4 个操作复用该连接的内存预算；复杂查询可按会话临时调大
work_mem = '${WORK_MEM_MB}MB'

# 会话临时表缓存 = shared_buffers ÷ 128 = ${SHARED_BUFFERS_MB}÷128 = ${TEMP_BUFFERS_MB}MB（限制 8MB~128MB）
temp_buffers = '${TEMP_BUFFERS_MB}MB'

#------------------------------------------------------------------------------
# WAL 与检查点
#------------------------------------------------------------------------------
# WAL 缓冲区 = shared_buffers ÷ 32 = ${SHARED_BUFFERS_MB}÷32 = ${WAL_BUFFERS_MB}MB（限制 1MB~16MB）
wal_buffers = '${WAL_BUFFERS_MB}MB'

# 最小 WAL = shared_buffers ÷ 4 = ${MIN_WAL_MB}MB（限制 512MB~4GB）
#   检查点后至少保留的 WAL 量，太小时 WAL 反复重建
min_wal_size = '${MIN_WAL_MB}MB'

# 最大 WAL = shared_buffers × 2 = ${MAX_WAL_MB}MB（限制 2GB~32GB）
#   WAL 超过该值触发检查点；适当放大可减少检查点频率与写放大
max_wal_size = '${MAX_WAL_MB}MB'

# 复制保留 WAL = max_wal_size ÷ 2 = ${WAL_KEEP_MB}MB（限制 512MB~8GB）
#   为从库断线重连保留的 WAL 量（替代已废弃的 wal_keep_segments）
wal_keep_size = '${WAL_KEEP_MB}MB'

# 检查点间隔 15min：TimescaleDB 官方建议，降低检查点频率
checkpoint_timeout = 15min

# 检查点写入平滑度 0.9：在 90% 检查点间隔内均匀写入，削峰
checkpoint_completion_target = 0.9

# WAL 压缩：开启后以少量 CPU 换取更小 WAL 体积与更少 IO
wal_compression = on

#------------------------------------------------------------------------------
# 并行查询与后台进程
#------------------------------------------------------------------------------
# 并行查询 worker 总数 = CPU 核数 = ${CPU_COUNT}
max_parallel_workers = ${MAX_PARALLEL_WORKERS}

# 单条查询并行 worker 上限 = CPU ÷ 2 = ${MAX_PARALLEL_WORKERS_PER_GATHER}
max_parallel_workers_per_gather = ${MAX_PARALLEL_WORKERS_PER_GATHER}

# 并行维护 worker 上限 = CPU ÷ 2 = ${MAX_PARALLEL_MAINTENANCE_WORKERS}
max_parallel_maintenance_workers = ${MAX_PARALLEL_MAINTENANCE_WORKERS}

# 后台 worker 总数 = max(8, CPU, 并行 worker + TimescaleDB worker + 4) = ${MAX_WORKER_PROCESSES}
max_worker_processes = ${MAX_WORKER_PROCESSES}

# TimescaleDB 后台 worker = CPU + 1 = ${TS_MAX_BACKGROUND_WORKERS}（上限 16）
timescaledb.max_background_workers = ${TS_MAX_BACKGROUND_WORKERS}

#------------------------------------------------------------------------------
# 自动清理（autovacuum）
#------------------------------------------------------------------------------
# 自动清理 worker 数 = CPU 核数，限制 3~8 → ${AUTOVACUUM_MAX_WORKERS}
autovacuum_max_workers = ${AUTOVACUUM_MAX_WORKERS}

# 自动清理 IO 预算 = CPU × 100，限制 200~2000 → ${AUTOVACUUM_COST_LIMIT}
#   值越大清理越快，但磁盘 IO 压力越高；SSD 可适当放大
autovacuum_vacuum_cost_limit = ${AUTOVACUUM_COST_LIMIT}

# 自动清理轮询间隔 10s：小表频繁更新时也能较快回收死元组
autovacuum_naptime = 10s

#------------------------------------------------------------------------------
# IO 与锁
#------------------------------------------------------------------------------
# 随机页读取成本 1.1：SSD 场景（HDD 建议 4.0）
random_page_cost = 1.1

# IO 并发 = CPU × 8，限制 16~200 → ${EFFECTIVE_IO_CONCURRENCY}（SSD 多队列并行 IO）
effective_io_concurrency = ${EFFECTIVE_IO_CONCURRENCY}

# 维护类 IO 并发 = CPU × 4，限制 8~100 → ${MAINTENANCE_IO_CONCURRENCY}
maintenance_io_concurrency = ${MAINTENANCE_IO_CONCURRENCY}

# 单事务锁上限 = max_connections ÷ 32，限制 64~512 → ${MAX_LOCKS_PER_TRANSACTION}
#   分区表/大批量 DDL 较多时需调大
max_locks_per_transaction = ${MAX_LOCKS_PER_TRANSACTION}

#------------------------------------------------------------------------------
# 复制
#------------------------------------------------------------------------------
# WAL 发送进程 = CPU × 2，限制 10~64 → ${MAX_WAL_SENDERS}
max_wal_senders = ${MAX_WAL_SENDERS}

# 复制槽数量与发送进程一致 → ${MAX_REPLICATION_SLOTS}
max_replication_slots = ${MAX_REPLICATION_SLOTS}

#------------------------------------------------------------------------------
# 预加载扩展（TimescaleDB / pg_stat_monitor 必须在 shared_preload_libraries 中）
#------------------------------------------------------------------------------
shared_preload_libraries = 'timescaledb,pg_stat_monitor'

# 大页：容器内通常不可用，显式关闭避免启动告警
huge_pages = off
CONF
}

emit_summary() {
cat <<SUMMARY
===== PostgreSQL 自动调优资源与关键参数 =====
内存        : ${MEM_MB}MB (${MEM_SOURCE})
CPU         : ${CPU_COUNT} 核 (${CPU_SOURCE})
连接数      : ${MAX_CONNECTIONS} (${CONN_SOURCE})
shared_buffers            : ${SHARED_BUFFERS_MB}MB
effective_cache_size      : ${EFFECTIVE_CACHE_SIZE_MB}MB
maintenance_work_mem      : ${MAINTENANCE_WORK_MEM_MB}MB
work_mem                  : ${WORK_MEM_MB}MB
wal_buffers               : ${WAL_BUFFERS_MB}MB
min_wal_size / max_wal_size: ${MIN_WAL_MB}MB / ${MAX_WAL_MB}MB
并行 worker (总数/单查询/维护): ${MAX_PARALLEL_WORKERS}/${MAX_PARALLEL_WORKERS_PER_GATHER}/${MAX_PARALLEL_MAINTENANCE_WORKERS}
TimescaleDB 后台 worker   : ${TS_MAX_BACKGROUND_WORKERS}
autovacuum worker / 预算  : ${AUTOVACUUM_MAX_WORKERS} / ${AUTOVACUUM_COST_LIMIT}
===========================================
SUMMARY
}

# 机器可读 JSON（供集群模式渲染 Patroni 配置使用）
emit_json() {
cat <<JSON
{
  "max_connections": ${MAX_CONNECTIONS},
  "superuser_reserved_connections": ${SUPERUSER_RESERVED},
  "shared_buffers": "${SHARED_BUFFERS_MB}MB",
  "effective_cache_size": "${EFFECTIVE_CACHE_SIZE_MB}MB",
  "maintenance_work_mem": "${MAINTENANCE_WORK_MEM_MB}MB",
  "work_mem": "${WORK_MEM_MB}MB",
  "temp_buffers": "${TEMP_BUFFERS_MB}MB",
  "wal_buffers": "${WAL_BUFFERS_MB}MB",
  "min_wal_size": "${MIN_WAL_MB}MB",
  "max_wal_size": "${MAX_WAL_MB}MB",
  "wal_keep_size": "${WAL_KEEP_MB}MB",
  "checkpoint_timeout": "15min",
  "checkpoint_completion_target": 0.9,
  "wal_compression": "on",
  "max_parallel_workers": ${MAX_PARALLEL_WORKERS},
  "max_parallel_workers_per_gather": ${MAX_PARALLEL_WORKERS_PER_GATHER},
  "max_parallel_maintenance_workers": ${MAX_PARALLEL_MAINTENANCE_WORKERS},
  "max_worker_processes": ${MAX_WORKER_PROCESSES},
  "timescaledb.max_background_workers": ${TS_MAX_BACKGROUND_WORKERS},
  "autovacuum_max_workers": ${AUTOVACUUM_MAX_WORKERS},
  "autovacuum_vacuum_cost_limit": ${AUTOVACUUM_COST_LIMIT},
  "autovacuum_naptime": "10s",
  "random_page_cost": 1.1,
  "effective_io_concurrency": ${EFFECTIVE_IO_CONCURRENCY},
  "maintenance_io_concurrency": ${MAINTENANCE_IO_CONCURRENCY},
  "max_locks_per_transaction": ${MAX_LOCKS_PER_TRANSACTION},
  "max_wal_senders": ${MAX_WAL_SENDERS},
  "max_replication_slots": ${MAX_REPLICATION_SLOTS},
  "shared_preload_libraries": "timescaledb,pg_stat_monitor",
  "huge_pages": "off"
}
JSON
}

case "$FORMAT" in
    conf)            emit_conf ;;
    yaml|--patroni)  emit_yaml ;;
    json)            emit_json ;;
    summary)         emit_summary ;;
    *)               echo "未知格式: $FORMAT（可选: conf | yaml | --patroni | json | summary）" >&2; exit 2 ;;
esac
