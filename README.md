# PostgreSQL + TimescaleDB 自定义镜像

基于 Ubuntu 的 Percona Distribution for PostgreSQL + TimescaleDB 自定义镜像，
兼容 Percona Operator for PostgreSQL，内置内存自动计算。

## 特性

- **基础镜像**：Ubuntu（沿用 [iflyelf/ubuntu-docker](https://github.com/iflyelf/ubuntu-docker) 的 Dockerfile 模板风格）
- **PostgreSQL**：Percona Distribution for PostgreSQL（`percona-ppg-server`）
- **TimescaleDB**：通过 packagecloud apt 源安装（`timescaledb-2-postgresql`）
- **扩展**：pgvector、pgaudit、pg_stat_monitor、pgbackrest、pgbouncer
- **HA**：内置 Patroni（pip 安装最新版），兼容 Percona Operator
- **内存自动计算**：容器启动时按 CPU/内存 limit 动态计算 PostgreSQL 参数
- **多架构**：linux/amd64 + linux/arm64
- **本地化**：中文 locale（zh_CN.UTF-8）+ Asia/Shanghai 时区

> **版本说明**：TimescaleDB 当前支持到 PostgreSQL 17，故 `PG_MAJOR=17`。
> PostgreSQL 18 支持后可在构建时通过 `--build-arg PG_MAJOR=18` 升级。

## 目录结构

```
docker-image/
├── Dockerfile                          # 镜像构建文件
├── scripts/
│   ├── docker-entrypoint.sh            # 容器入口（内存计算 + Patroni 集成）
│   └── postgresql-config-tuner.sh      # 内存/CPU 自动计算脚本
└── .github/workflows/
    └── docker-publish.yml              # GitHub Actions 自动构建
```

## 内存自动计算

`postgresql-config-tuner.sh` 探测容器 cgroup 限制（v2 优先，回退 v1 / 宿主机），
按以下公式计算参数（对齐生产 `postgresql.base.conf` 的注释公式）：

| 参数                            | 计算公式                                      |
|---------------------------------|-----------------------------------------------|
| shared_buffers                  | 内存 × 25%                                     |
| effective_cache_size            | 内存 × 75%                                     |
| maintenance_work_mem            | 内存 × 5%（上限 2048MB）                        |
| work_mem                        | (内存 × 25%) / (max_connections × 4)，≥ 4MB    |
| wal_buffers                     | shared_buffers / 32（上限 16MB）               |
| max_worker_processes            | max(CPU, 并行 worker + TS worker + 4)          |
| max_parallel_workers            | CPU 核数                                       |
| max_parallel_workers_per_gather | CPU / 2（≥ 2）                                 |
| timescaledb.max_background_workers | CPU + 1（上限 16）                          |

### 独立测试

```bash
# 1. 自动探测容器 cgroup 限制（默认）
./scripts/postgresql-config-tuner.sh --patroni

# 2. 手动指定 CPU/内存（支持 K8s 资源格式：8Gi/4/500m 等）
PG_MEMORY_LIMIT=8Gi PG_CPU_LIMIT=4 ./scripts/postgresql-config-tuner.sh --patroni

# 3. 混合模式：仅指定内存，CPU 自动探测
PG_MEMORY_LIMIT=16Gi ./scripts/postgresql-config-tuner.sh --patroni

# 4. 模拟指定 max_connections（默认 10000）
PG_MAX_CONNECTIONS=1000 PG_MEMORY_LIMIT=8Gi PG_CPU_LIMIT=4 ./scripts/postgresql-config-tuner.sh --patroni

# 5. 输出 postgresql.conf 格式（默认）
PG_MEMORY_LIMIT=8Gi PG_CPU_LIMIT=4 ./scripts/postgresql-config-tuner.sh conf
```

**说明：**
- `PG_MEMORY_LIMIT` / `PG_CPU_LIMIT` 未指定时，自动从容器 cgroup 探测（优先 v2，回退 v1）
- 手动指定支持 K8s 格式：内存(8Gi/4096Mi/...)、CPU(4/2.5/500m/...)
- 此脚本与 `../update-pg-params.py` 计算公式完全一致，相同输入产出完全相同结果

## 本地构建

```bash
# 单架构本地构建
docker build -t iflyelf/postgres:latest .

# 指定 PG 版本
docker build --build-arg PG_MAJOR=17 -t iflyelf/postgres:pg17 .

# 多架构构建并推送（需 buildx）
docker buildx build --platform linux/amd64,linux/arm64 \
  -t iflyelf/postgres:latest --push .
```

## 自动构建（GitHub Actions）

`.github/workflows/docker-publish.yml` 触发条件：
- push 修改 `Dockerfile` 或 `scripts/**`
- 手动触发（workflow_dispatch）
- 每天定时构建（cron，保持所有模块最新）
- Star 触发（watch）

需在仓库 Secrets 配置：
- `DOCKER_USERNAME`：DockerHub 用户名
- `DOCKER_PASSWORD`：DockerHub 访问令牌

推送镜像标签：`<DOCKER_USERNAME>/postgres:latest`

## 与 Percona Operator 集成

镜像的 entrypoint 会自动识别运行场景：
1. **Patroni 接管**（Operator 环境）：生成调优片段后透传 Patroni 命令
2. **其他命令**：直接透传（诊断、sleep 等）
3. **独立 postgres**：initdb + 加载扩展 + 启动（本地测试用）

在 pg-cluster 的 `values-custom.yaml` 中通过 `image: docker.io/iflyelf/postgres:latest`
引用。注意：Operator 环境下 Patroni 的 `dynamicConfiguration.postgresql.parameters`
优先级最高，会覆盖镜像内 tuner 写入的 include 配置，因此 values 中的内存参数需按
`instances.resources.limits.memory` 手动计算（或参考 tuner 公式）。
