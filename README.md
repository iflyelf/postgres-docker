# PostgreSQL + TimescaleDB 自定义镜像

基于 Ubuntu 的 Percona Distribution for PostgreSQL + TimescaleDB 自定义镜像，
兼容 Percona Operator for PostgreSQL，内置内存自动计算。

支持 `linux/amd64` 与 `linux/arm64` 多架构，标签为 `latest` 与 PG 大版本号（如 `17`）。

## 特性

- **多阶段构建**：builder = `iflyelf/ubuntu:latest`，runtime = `iflyelf/ubuntu:lite`
- **PostgreSQL**：Percona Distribution for PostgreSQL（`percona-ppg-server`）
- **TimescaleDB**：通过 packagecloud apt 源安装（`timescaledb-2-postgresql`，含 `timescaledb-tune`）
- **扩展**：pgvector、pgaudit、pg_stat_monitor、pg_repack、wal2json、pgbackrest、pgbouncer、pgbadger
- **HA**：内置 Patroni（独立 venv `/opt/patroni`，版本固定并自动跟进），兼容 Percona Operator
- **自动调优**：容器启动时按 CPU / 内存 limit 自动计算连接数、缓冲区、WAL、并行、autovacuum、IO 等参数，
  生成带中文注释的 `conf.d/00-auto-tuned.conf` 并自动 include，日志打印资源与关键参数摘要
- **本地化**：中文 locale（zh_CN.UTF-8，另生成 en_US.UTF-8 兼容 Operator）+ Asia/Shanghai 时区

> **版本说明**：`PG_MAJOR=17`，与现有数据目录保持一致。Percona 与 TimescaleDB 源已提供 PG 18，
> 升级需先用 `pg_upgrade` 迁移数据目录，再通过 `--build-arg PG_MAJOR=18` 构建。

## 多阶段构建

| 阶段 | 基础镜像 | 作用 |
| --- | --- | --- |
| builder | `iflyelf/ubuntu:latest` | 已预装 Python / pip / gpg / curl 等完整工具链：生成 Percona 与 TimescaleDB 的 apt 源及签名密钥、下载并 GPG 校验 gosu、在 venv 中 pip 安装 Patroni |
| runtime | `iflyelf/ubuntu:lite` | 拷贝 apt 源、gosu、Patroni venv，仅 apt 安装 PostgreSQL 及运行依赖，镜像更小 |

构建产物（builder → runtime）：

| 产物 | 路径 |
| --- | --- |
| Percona / TimescaleDB apt 源 | `/etc/apt/sources.list.d/percona-*.list`、`timescaledb.list` |
| 签名密钥（`signed-by`，不写入全局 trusted.gpg） | `/usr/share/keyrings/percona-keyring.gpg`、`timescaledb.gpg` |
| gosu | `/usr/local/bin/gosu` |
| Patroni venv | `/opt/patroni`（`patroni`、`patronictl` 软链到 `/usr/local/bin`） |

运行阶段在 `ubuntu:lite` 基础上补装的依赖：

| 依赖 | 用途 |
| --- | --- |
| `python3` | Patroni venv 解释器 |
| `python3-yaml`、`python3-psycopg2` | Operator 侧可能调用的系统 python 脚本 |
| `libnss-wrapper` | Operator 以任意 UID 运行时伪造 passwd（软链到 `/usr/lib64/libnss_wrapper.so`） |
| `sudo` | postgres 用户受限提权（mkdir/chmod/chown/psql/pg_dump） |
| `libdbd-pg-perl`、`libdbi-perl` | pgbadger 等 perl 工具 |
| `ssl-cert`、`lsb-release` | postgresql-common 依赖 |
| `rsync`、`zstd`、`xz-utils`、`numactl`、`net-tools`、`ncat`、`debsums` | 备份恢复与诊断工具 |
| `locales`、`tzdata`、`ca-certificates` | 本地化、时区、TLS 根证书 |
| `etcd-server`、`etcd-client` | 3 节点集群模式的 DCS（Patroni 依赖 etcd） |

运行阶段环境变量：

| 变量 | 默认值 |
| --- | --- |
| `PG_MAJOR` | `17` |
| `PGHOME` / `PGDATA` | `/data/postgres` / `/data/postgres/data` |
| `PATH` | 追加 `/usr/lib/postgresql/${PG_MAJOR}/bin` 与 `/opt/patroni/bin` |
| `PATRONI_HOME` / `PATRONI_VERSION` / `GOSU_VERSION` | Patroni venv 路径与组件版本 |
| `LANG` / `TZ` | `zh_CN.UTF-8` / `Asia/Shanghai` |

构建末尾会自检 `gosu`、`patroni`、`patronictl`、`postgres`、`pgbackrest`、`pgbouncer`、
`etcd`、`etcdctl`、`PyYAML` 可执行/可用，并校验 `timescaledb.so`、`pg_stat_monitor.so`、
`vector.so` 存在，任一缺失则构建失败。

## 目录结构

```
postgres-docker/
├── Dockerfile                          # 多阶段构建文件
├── docker-compose.yml                  # 单机部署（1 节点）
├── docker-compose.cluster.yml          # 3 节点集群（每节点 etcd + Patroni + PostgreSQL）
├── .env.example                        # 环境变量样例（复制为 .env）
├── conf/patroni/patroni.yml.tmpl       # 集群模式 Patroni 配置模板
├── scripts/
│   ├── docker-entrypoint.sh            # 单机入口（自动调优 + 独立运行 PostgreSQL）
│   ├── cluster-entrypoint.sh           # 集群入口（Patroni + PostgreSQL，可选嵌入式 etcd）
│   ├── etcd-entrypoint.sh              # 独立 etcd 容器入口（DCS）
│   ├── postgresql-config-tuner.sh      # CPU/内存/连接数自动计算（conf/yaml/json/summary）
│   ├── render-patroni-config.py        # 渲染 Patroni 配置并合并自动调优参数
│   └── update-version.sh               # 组件版本号同步脚本（GitHub API）
└── .github/workflows/
    ├── docker-publish.yml              # 构建并推送 Docker Hub + 华为云 SWR
    └── update-version.yml              # 每日自动更新版本号
```

## 镜像获取

```bash
# Docker Hub（国外）
docker pull iflyelf/postgres:latest

# 华为云 SWR（国内推荐）
docker pull swr.cn-east-3.myhuaweicloud.com/iflyelf/postgres:latest
```

## 运行

```bash
docker run -d --name postgres \
  -e POSTGRES_PASSWORD=change_me \
  -p 5432:5432 \
  -v pgdata:/data/postgres \
  iflyelf/postgres:latest
```

## 单机部署（docker compose）

```bash
cp .env.example .env          # 修改 POSTGRES_PASSWORD 等
docker compose up -d
docker compose logs -f postgres
```

`docker-compose.yml` 要点：

| 项目 | 配置 |
| --- | --- |
| 镜像 | `iflyelf/postgres:latest`（可换成 SWR 地址） |
| 数据/归档/日志 | `./data/postgres`、`./archive/postgres`、`./logs/postgres` |
| 网络 | 自定义桥接网络 `pg_net`（`172.22.0.0/24` + `fe9a::/64`），固定 IP `172.22.0.2` / `fe9a::2` |
| 时区 | 挂载宿主机 `/usr/share/zoneinfo`、`/etc/localtime` |
| 共享内存 | `shm_size: 1gb`（并行查询/大排序需要） |
| 健康检查 | `pg_isready`，每 30s 一次 |
| 初始化参数 | `POSTGRES_INITDB_ARGS` 统一使用中文 UTF-8 locale |
| 自动建库 | 首次初始化后按 `POSTGRES_DB` 创建业务库（库名仅支持字母/数字/下划线/短横线） |
| 权限处理 | 容器以 root 启动，修正宿主挂载目录属主后自动降权到 `postgres`(26)，无需手工 chown |
| 自动调优 | 通过 `.env` 的 `PG_MEMORY_LIMIT` / `PG_CPU_LIMIT` / `PG_MAX_CONNECTIONS` 覆盖 |
| 自定义参数 | 取消注释 `./conf/postgres/99-custom.conf` 挂载，覆盖自动调优结果 |

## 3 节点集群（docker compose + Patroni + etcd）

架构：**etcd 独立容器**（3 个）+ **PostgreSQL 节点**（3 个，各含 Patroni）。
etcd 与数据库生命周期解耦——重启数据库节点不会影响 DCS，重启 etcd 也不影响数据节点。

```
etcd1 (172.22.1.21)  etcd2 (172.22.1.22)  etcd3 (172.22.1.23)   ← DCS，quorum=2
        │                    │                    │
        └────────────┬───────┴────────────┬───────┘
                     ▼                    ▼
              pg1 (172.22.1.11)    pg2/pg3 (172.22.1.12/13)      ← Patroni + PostgreSQL
```

```bash
cp .env.example .env          # 必须修改 POSTGRES_PASSWORD / REPLICATION_PASSWORD / REWIND_PASSWORD
docker compose -f docker-compose.cluster.yml up -d

# 查看集群状态（任意节点执行）
docker exec pg1 patronictl -c /run/patroni/patroni.yml list
# + Cluster: postgres-cluster ---+-----+------------+-----+
# | Member | Host        | Role    | State     | TL | Lag |
# | pg1    | 172.22.1.11 | Leader  | running   |  1 |     |
# | pg2    | 172.22.1.12 | Replica | streaming |  1 |   0 |
# | pg3    | 172.22.1.13 | Replica | streaming |  1 |   0 |
```

| 节点 | 角色 | IPv4 | IPv6 | 端口 | 数据目录 |
| --- | --- | --- | --- | --- | --- |
| etcd1 | DCS | `172.22.1.21` | `fe9a:1::21` | 2379/2380（仅内网） | `./data/etcd1` |
| etcd2 | DCS | `172.22.1.22` | `fe9a:1::22` | 2379/2380（仅内网） | `./data/etcd2` |
| etcd3 | DCS | `172.22.1.23` | `fe9a:1::23` | 2379/2380（仅内网） | `./data/etcd3` |
| pg1 | PostgreSQL | `172.22.1.11` | `fe9a:1::11` | `5432` / API `8008` | `./data/pg1` |
| pg2 | PostgreSQL | `172.22.1.12` | `fe9a:1::12` | `5433` / API `8009` | `./data/pg2` |
| pg3 | PostgreSQL | `172.22.1.13` | `fe9a:1::13` | `5434` / API `8010` | `./data/pg3` |

网络名为 `pg_cluster_net`，网段 `172.22.1.0/24`（网关 `172.22.1.1`）+ `fe9a:1::/64`（网关 `fe9a:1::1`）。

集群要点：

- **DCS**：独立 `etcd` 容器（镜像内置 Ubuntu 的 etcd 3.5），首次引导 `state=new`，重启自动切 `existing`；
  数据持久化在 `./data/etcdN`，重启不影响集群
- **配置模板**：`conf/patroni/patroni.yml.tmpl`，占位符由环境变量填充；运行时渲染到容器内
  `/run/patroni/patroni.yml`（root 独占目录，避免重启时文件属主冲突）
- **自动调优**：每个 pg 节点按自身 CPU/内存自动计算参数，合并进 Patroni 的 `postgresql.parameters`
  （日志前缀 `>>> [render]`）；设 `CLUSTER_AUTOTUNE=false` 可改用模板默认参数
- **故障切换**：`docker exec pg1 patronictl -c /run/patroni/patroni.yml switchover` 手动切换；
  `docker stop pg2` 可验证自动 failover，`docker start pg2` 会自动 pg_rewind 后以副本回归
- **连接**：应用连主库时可连任一节点的 `5432`（固定 IP），或按 `patronictl list` 的 Leader 指向；
  生产建议在前面加 HAProxy/pgbouncer 做读写分离
- **扩缩容**：将新节点加入 `ETCD_INITIAL_CLUSTER` 与 `ETCD_HOSTS`，并用相同 `PATRONI_SCOPE` 启动
- **嵌入式 etcd（可选）**：把某个 pg 服务的 `ETCD_EMBEDDED` 改回 `true` 即可在该容器内同时跑 etcd
  （每个容器一个 etcd 成员，只需 3 个容器；生产不推荐）

> 宿主机 Docker 内置 DNS 在本环境不可用，集群全部使用固定 IP 通信（`ETCD_HOSTS`、`PATRONI_CONNECT_HOST`）。
> 集群密码写入 `patroni.yml.tmpl` 的占位符，由 `.env` 注入，不要提交 `.env`（已在 `.gitignore` 中忽略）。

### 网络规划（避免与其它组件冲突）

本仓库占用 **172.22.x** 段，与现有组件互不重叠：

| 用途 | 网络/桥接名 | IPv4 | IPv6 | 容器 IP |
| --- | --- | --- | --- | --- |
| PostgreSQL 单机 | `pg_net` | `172.22.0.0/24`（网关 `.1`） | `fe9a::/64`（网关 `fe9a::1`） | `172.22.0.2` / `fe9a::2` |
| PostgreSQL 集群 | `pg_cluster_net` | `172.22.1.0/24`（网关 `.1`） | `fe9a:1::/64`（网关 `fe9a:1::1`） | pg `172.22.1.11~13` / `fe9a:1::11~13`，etcd `172.22.1.21~23` / `fe9a:1::21~23` |

同主机其它组件的网段占用（规划时已核对，勿重复使用）：

| 组件 | IPv4 | IPv6 |
| --- | --- | --- |
| nginx / dns / clash / workers | `172.20.0.0/24` | `fd99::/64` |
| mysql | `172.21.0.0/24` | `fe99::/64` |
| mysql MGR 集群 | `172.21.1.0/24` | `fe99:1::/64` |
| hugo / singbox | `172.186.0.0/24` | `2066::/64` |
| Docker 默认 bridge | `172.188.0.0/24` | `2088::/64` |

命名规则：网络/桥接名以组件名开头（`pg_`、`mysql_`、`nginx_`…），不使用 `app_net`。
桥接名受 Linux 接口名 15 字符限制（超长会报 `numerical result out of range`）。

> 部署前建议再确认宿主机占用：`ip -4 route | grep 172.` 与 `docker network ls`。

## CPU / 内存自动调优

容器启动时 `postgresql-config-tuner.sh` 探测容器 CPU / 内存限制
（cgroup v2 优先，回退 v1，最后用宿主机值），自动计算连接数、内存、WAL、并行、
autovacuum、IO、复制等参数，**生成带中文注释的配置**并写入 `$PGHOME/conf.d/00-auto-tuned.conf`，
由 `include_dir` 引入；容器日志会打印资源与关键参数摘要。

- 每次启动重新生成（资源 limit 变化后重启即生效）
- 旧数据目录若缺少 `include_dir`，entrypoint 会自动补齐后生效
- 生成内容每项都带中文注释与计算公式，例如：

```conf
# 共享缓冲区 = 内存 × 25% = 8192MB × 25% = 2048MB（限制 128MB~64GB）
#   数据库最热数据缓存，建议为物理内存的 25%
shared_buffers = '2048MB'

# 单次排序/哈希内存 = (内存 × 25%) ÷ (max_connections × 4) = 4MB（限制 4MB~256MB）
#   (8192×25%) ÷ (512×4) = 1MB
#   并发因子 4 表示同时约有 4 个操作复用该连接的内存预算；复杂查询可按会话临时调大
work_mem = '4MB'
```

### 计算公式

| 参数 | 计算公式 | 取值范围 |
| --- | --- | --- |
| `max_connections` | min(内存MB ÷ 16, CPU × 150 + 100) | 100~5000 |
| `superuser_reserved_connections` | max_connections ÷ 100 | 3~20 |
| `shared_buffers` | 内存 × 25% | 128MB~64GB |
| `effective_cache_size` | 内存 × 75% | — |
| `maintenance_work_mem` | 内存 × 5% | 64MB~2GB |
| `work_mem` | (内存 × 25%) ÷ (max_connections × 4) | 4MB~256MB |
| `temp_buffers` | shared_buffers ÷ 128 | 8MB~128MB |
| `wal_buffers` | shared_buffers ÷ 32 | 1MB~16MB |
| `min_wal_size` | shared_buffers ÷ 4 | 512MB~4GB |
| `max_wal_size` | shared_buffers × 2 | 2GB~32GB |
| `wal_keep_size` | max_wal_size ÷ 2 | 512MB~8GB |
| `max_parallel_workers` | CPU 核数 | ≥2 |
| `max_parallel_workers_per_gather` | CPU ÷ 2 | ≥2 |
| `max_parallel_maintenance_workers` | CPU ÷ 2 | ≥2 |
| `max_worker_processes` | max(8, CPU, 并行 worker + TS worker + 4) | — |
| `timescaledb.max_background_workers` | CPU + 1 | 2~16 |
| `autovacuum_max_workers` | CPU 核数 | 3~8 |
| `autovacuum_vacuum_cost_limit` | CPU × 100 | 200~2000 |
| `effective_io_concurrency` | CPU × 8（SSD） | 16~200 |
| `maintenance_io_concurrency` | CPU × 4 | 8~100 |
| `max_locks_per_transaction` | max_connections ÷ 32 | 64~512 |
| `max_wal_senders` / `max_replication_slots` | CPU × 2 | 10~64 |

固定策略（不随资源变化）：`checkpoint_timeout=15min`（TimescaleDB 建议）、
`checkpoint_completion_target=0.9`、`wal_compression=on`、`random_page_cost=1.1`（SSD）、
`autovacuum_naptime=10s`、`huge_pages=off`（容器内不可用），
`shared_preload_libraries='timescaledb,pg_stat_monitor'`。

### 环境变量覆盖

| 变量 | 说明 |
| --- | --- |
| `PG_MEMORY_LIMIT` | 内存上限，支持 `8Gi` / `8192Mi` / 字节数 |
| `PG_CPU_LIMIT` | CPU 上限，支持 `4` / `2.5` / `500m` |
| `PG_MAX_CONNECTIONS` | 直接指定连接数（例如配合 pgbouncer 连接池时调小） |

### 独立测试

```bash
# 1. 自动探测容器 cgroup 限制，输出带注释的 postgresql.conf 片段（默认）
./scripts/postgresql-config-tuner.sh conf

# 2. 手动指定 CPU/内存（支持 K8s 资源格式：8Gi/4/500m 等）
PG_MEMORY_LIMIT=8Gi PG_CPU_LIMIT=4 ./scripts/postgresql-config-tuner.sh conf

# 3. 混合模式：仅指定内存，CPU 自动探测
PG_MEMORY_LIMIT=16Gi ./scripts/postgresql-config-tuner.sh conf

# 4. 直接指定连接数
PG_MAX_CONNECTIONS=1000 PG_MEMORY_LIMIT=8Gi PG_CPU_LIMIT=4 ./scripts/postgresql-config-tuner.sh conf

# 5. 输出资源探测与关键参数摘要（容器启动日志中同样会打印）
PG_MEMORY_LIMIT=8Gi PG_CPU_LIMIT=4 ./scripts/postgresql-config-tuner.sh summary

# 6. 输出 Patroni dynamicConfiguration 片段（带中文注释）
./scripts/postgresql-config-tuner.sh --patroni
```

**说明：**
- `PG_MEMORY_LIMIT` / `PG_CPU_LIMIT` 未指定时，自动从容器 cgroup 探测（优先 v2，回退 v1）
- 手动指定支持 K8s 格式：内存(8Gi/4096Mi/...)、CPU(4/2.5/500m/...)
- 参数整体按 SSD + 容器化 OLTP 场景设定；HDD 或分析型负载建议按注释自行调整

## 本地构建

```bash
# 单架构本地构建
docker build -t iflyelf/postgres:latest .

# 指定 PG 版本
docker build --build-arg PG_MAJOR=17 -t iflyelf/postgres:17 .

# 构建环境需代理时（容器内 DNS 不通的场景）
docker build --network host \
  --build-arg HTTP_PROXY=http://<proxy>:7890 \
  --build-arg HTTPS_PROXY=http://<proxy>:7890 \
  -t iflyelf/postgres:latest .
```

## 自动构建（GitHub Actions）

### 镜像构建 `docker-publish.yml`

触发条件：
- push 修改 `Dockerfile`、`scripts/**` 或工作流本身
- 手动触发（workflow_dispatch）
- 每天中国时间早 5 点定时构建（跟进 apt 源中 PG 小版本、TimescaleDB 等更新）
- Star 触发（watch）

同一分支只保留最新一次构建（`concurrency` + `cancel-in-progress`），快速连续提交时自动取消旧构建。

作业流程：

1. **prepare**：执行 `scripts/update-version.sh` 同步版本号并提交，读取 `PG_MAJOR`
2. **build**：amd64（`ubuntu-latest`）与 arm64（`ubuntu-24.04-arm`）并行原生构建，
   推送 `latest-<arch>` / `<PG_MAJOR>-<arch>` 单架构标签，每架构独立 GHA 缓存
3. **merge**：用 `docker manifest` 合并为多架构清单 `latest` 与 `<PG_MAJOR>`
   （Docker v2 manifest list，兼容华为云 SWR），并调用 SWR API 将仓库设为公开

### 多架构构建（不使用 QEMU）

`amd64` 和 `arm64` 在两个**原生 runner** 上并行构建（`ubuntu-latest` 和 `ubuntu-24.04-arm`），
各自先推送 `latest-amd64`、`latest-arm64` 这类单架构标签，最后由 `merge` 作业用
`docker manifest` 合并成多架构清单。整个过程不需要 QEMU 模拟，构建时间从约 2 小时降到 10~20 分钟，
产出的仍是 Docker v2 manifest list，华为云 SWR 可以正常拉取。

| 架构 | Runner | 说明 |
| --- | --- | --- |
| amd64 | `ubuntu-latest`（x64 原生） | 直接编译，无需模拟 |
| arm64 | `ubuntu-24.04-arm`（arm64 原生） | 与 x64 速度相当；public 仓库免费 |

合并前每个架构各自推送单架构标签（`latest-amd64`、`latest-arm64`、`17-amd64`、`17-arm64`），
`merge` 作业再用 `docker manifest create/push` 生成多架构清单 `latest`、`17`：

```bash
docker manifest create <repo>:latest --amend <repo>:latest-amd64 <repo>:latest-arm64
docker manifest push --purge <repo>:latest
```

选择 `docker manifest` 而非 `buildx imagetools` 的原因：前者产出 Docker v2 manifest list，
华为云 SWR 可正常识别；`imagetools` 会生成 OCI index，SWR 部分场景不兼容。

> 若仓库为私有（arm runner 需付费），可把 arm64 作业改回
> `runs-on: ubuntu-latest` + `docker/setup-qemu-action`，或在 `matrix` 中只保留 amd64。

实测耗时（构建 #87）：amd64 约 5.6 分钟、arm64 约 6 分钟（两者并行），合并清单约 2 分钟。

推送目标：

| 仓库 | 镜像 |
| --- | --- |
| Docker Hub | `<DOCKER_USERNAME>/postgres:latest`、`<DOCKER_USERNAME>/postgres:17` |
| 华为云 SWR | `swr.cn-east-3.myhuaweicloud.com/iflyelf/postgres:latest`、`:17` |

### 版本自动更新 `update-version.yml`

每天中国时间早 4 点（早于构建）通过 GitHub API 获取最新**稳定** release（排除 prerelease/draft
与 rc/beta/alpha 等，只升不降），更新 Dockerfile 中的 `ARG` 并自动提交：

| ARG | 来源 |
| --- | --- |
| `GOSU_VERSION` | [tianon/gosu](https://github.com/tianon/gosu) |
| `PATRONI_VERSION` | [patroni/patroni](https://github.com/patroni/patroni) |

不自动更新的部分：
- `PG_MAJOR`：跨大版本需 `pg_upgrade`，必须人工评估
- PostgreSQL 小版本、TimescaleDB、pgvector 等：由 apt 源在每次构建时自动取最新

本地检查：

```bash
GH_TOKEN=<可选, 提高 API 限额> bash scripts/update-version.sh
```

### 所需 Secrets

| Secret | 说明 |
| --- | --- |
| `DOCKER_USERNAME` / `DOCKER_PASSWORD` | Docker Hub 凭据 |
| `SWR_USERNAME` / `SWR_PASSWORD` | 华为云 SWR 登录凭据（`区域@AK` / 登录密钥） |
| `SWR_AK` / `SWR_SK` | 华为云账号 AK/SK，用于将 SWR 仓库设为公开（可选） |

## 与 Percona Operator 集成

镜像的 entrypoint 会自动识别运行场景：
1. **Patroni 接管**（Operator 环境）：生成调优片段后透传 Patroni 命令
2. **其他命令**：直接透传（诊断、sleep 等）
3. **独立 postgres**：initdb + 加载扩展 + 启动（本地测试用）

在 pg-cluster 的 `values-custom.yaml` 中通过 `image: docker.io/iflyelf/postgres:latest`
（国内可用 `swr.cn-east-3.myhuaweicloud.com/iflyelf/postgres:latest`）引用。
注意：Operator 环境下 Patroni 的 `dynamicConfiguration.postgresql.parameters`
优先级最高，会覆盖镜像内 tuner 写入的 include 配置，因此 values 中的内存参数需按
`instances.resources.limits.memory` 手动计算（或参考 tuner 公式）。

postgres 用户固定为 UID/GID `26`（对齐 Percona 官方镜像），保证 pgBackRest sidecar 可读取数据文件。
