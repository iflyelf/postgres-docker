#############################################################################
#  iflyelf/postgres (Percona PostgreSQL + TimescaleDB + Patroni) 多阶段构建
#  - builder(构建阶段) = iflyelf/ubuntu:latest
#      已预装 Python / pip / gpg / curl 等完整工具链, 在此完成:
#        1. 生成 Percona / TimescaleDB 的 apt 源与签名密钥
#        2. 下载并 GPG 校验 gosu
#        3. 在独立 venv(/opt/patroni) 中 pip 安装 Patroni
#  - runtime(运行阶段) = iflyelf/ubuntu:lite
#      拷贝上述构建产物, 仅通过 apt 安装 PostgreSQL 及其运行依赖, 镜像更小。
#############################################################################

# ========================= 全局版本变量(两个阶段共享) =========================
# PG 大版本(保持与线上数据目录一致; 跨大版本升级需 pg_upgrade)
ARG PG_MAJOR=17
# gosu     https://github.com/tianon/gosu
ARG GOSU_VERSION=1.20
# Patroni  https://github.com/patroni/patroni
ARG PATRONI_VERSION=4.1.5

# 公共路径
ARG PATRONI_HOME=/opt/patroni


####################################################################
#                     构建阶段 (builder)                            #
####################################################################
FROM iflyelf/ubuntu:latest AS builder

LABEL org.opencontainers.image.authors="iflyelf" \
      org.opencontainers.image.vendor="iflyelf"

# buildx 自动注入的目标架构
ARG TARGETARCH
ARG TARGETVARIANT

# 继承全局版本变量
ARG PG_MAJOR
ARG GOSU_VERSION
ARG PATRONI_VERSION
ARG PATRONI_HOME

ARG DEBIAN_FRONTEND=noninteractive

# ***** 1. 生成 Percona / TimescaleDB apt 源(产物: keyrings + sources.list.d) *****
RUN set -eux && \
    CODENAME="$(lsb_release -sc)" && \
    mkdir -p /out/keyrings /out/sources && \
    # Percona: 通过官方 percona-release 工具生成 ppg-${PG_MAJOR} 源
    wget -q https://repo.percona.com/apt/percona-release_latest.generic_all.deb -O /tmp/percona-release.deb && \
    dpkg -i /tmp/percona-release.deb && \
    percona-release setup ppg-${PG_MAJOR} && \
    cp /usr/share/keyrings/percona-keyring.gpg /out/keyrings/ && \
    cp /etc/apt/sources.list.d/percona-*.list /out/sources/ && \
    # TimescaleDB: packagecloud 源(signed-by 独立密钥, 不污染全局 trusted.gpg)
    curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey | gpg --dearmor -o /out/keyrings/timescaledb.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/timescaledb.gpg] https://packagecloud.io/timescale/timescaledb/ubuntu/ ${CODENAME} main" \
        > /out/sources/timescaledb.list && \
    # 提前校验源中存在所需包, 避免运行阶段才失败
    cp /out/keyrings/timescaledb.gpg /usr/share/keyrings/ && \
    cp /out/sources/timescaledb.list /etc/apt/sources.list.d/ && \
    apt-get update -qq && \
    for pkg in percona-ppg-server-${PG_MAJOR} timescaledb-2-postgresql-${PG_MAJOR}; do \
        apt-cache show "$pkg" > /dev/null || { echo "ERROR: 源中缺少 $pkg" >&2; exit 1; }; \
    done && \
    rm -rf /var/lib/apt/lists/* /tmp/percona-release.deb

# ***** 2. 下载并校验 gosu(产物: /out/gosu) *****
RUN set -eux && \
    dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')" && \
    wget -q -O /out/gosu "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${dpkgArch}" && \
    wget -q -O /tmp/gosu.asc "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${dpkgArch}.asc" && \
    export GNUPGHOME="$(mktemp -d)" && \
    gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4 && \
    gpg --batch --verify /tmp/gosu.asc /out/gosu && \
    gpgconf --kill all && \
    rm -rf "$GNUPGHOME" /tmp/gosu.asc && \
    chmod +x /out/gosu && \
    /out/gosu --version

# ***** 3. 安装 Patroni 到独立 venv(产物: ${PATRONI_HOME}) *****
# builder 与 runtime 同为 Ubuntu resolute, 系统 python3 版本一致, venv 可直接拷贝复用
RUN set -eux && \
    python3 -m venv ${PATRONI_HOME} && \
    ${PATRONI_HOME}/bin/pip install --no-cache-dir --upgrade pip && \
    ${PATRONI_HOME}/bin/pip install --no-cache-dir \
        "patroni[psycopg3]==${PATRONI_VERSION}" \
        python-json-logger && \
    ${PATRONI_HOME}/bin/patroni --version && \
    # 清理字节码缓存, 减小体积
    find ${PATRONI_HOME} -name '__pycache__' -type d -prune -exec rm -rf {} +


####################################################################
#                     运行阶段 (runtime)                            #
####################################################################
FROM iflyelf/ubuntu:lite

LABEL org.opencontainers.image.authors="iflyelf" \
      org.opencontainers.image.vendor="iflyelf" \
      org.opencontainers.image.description="Percona PostgreSQL + TimescaleDB + Patroni, runtime on ubuntu:lite"

ARG TARGETARCH
ARG TARGETVARIANT

# 时区设置
ARG TZ=Asia/Shanghai
ENV TZ=$TZ
# 语言设置
ARG LANG=zh_CN.UTF-8
ENV LANG=$LANG

# 镜像变量
ARG DOCKER_IMAGE=iflyelf/postgres
ENV DOCKER_IMAGE=$DOCKER_IMAGE
ARG DOCKER_IMAGE_OS=ubuntu
ENV DOCKER_IMAGE_OS=$DOCKER_IMAGE_OS
ARG DOCKER_IMAGE_TAG=latest
ENV DOCKER_IMAGE_TAG=$DOCKER_IMAGE_TAG

# 环境设置
ARG DEBIAN_FRONTEND=noninteractive
ENV DEBIAN_FRONTEND=$DEBIAN_FRONTEND

# 继承全局版本变量
ARG PG_MAJOR
ENV PG_MAJOR=$PG_MAJOR
ARG GOSU_VERSION
ENV GOSU_VERSION=$GOSU_VERSION
ARG PATRONI_VERSION
ENV PATRONI_VERSION=$PATRONI_VERSION
ARG PATRONI_HOME
ENV PATRONI_HOME=$PATRONI_HOME

# PG 可执行文件 + Patroni venv 加入 PATH
ENV PATH=$PATH:/usr/lib/postgresql/$PG_MAJOR/bin:$PATRONI_HOME/bin

# 工作目录
ARG PGHOME=/data/postgres
ENV PGHOME=$PGHOME
# 数据目录
ARG PGDATA=/data/postgres/data
ENV PGDATA=$PGDATA

# 运行依赖(ubuntu:lite 未包含的部分)
#   python3                       -> Patroni venv 解释器
#   python3-yaml/python3-psycopg2 -> Patroni 配置渲染与系统脚本
#   libnss-wrapper                -> Operator 以任意 UID 运行时伪造 passwd
#   sudo                          -> postgres 用户受限提权(mkdir/chmod/chown)
#   libdbd-pg-perl/libdbi-perl    -> pgbadger 等 perl 工具
#   ssl-cert/lsb-release          -> postgresql-common 依赖与脚本识别发行版
#   rsync/zstd/numactl/...        -> 备份/恢复与诊断工具
#   etcd-server/etcd-client       -> 3 节点集群模式的 DCS（Patroni 依赖 etcd）
ARG PKG_DEPS="\
    python3 \
    python3-yaml \
    python3-psycopg2 \
    libnss-wrapper \
    sudo \
    libdbd-pg-perl \
    libdbi-perl \
    ssl-cert \
    lsb-release \
    rsync \
    zstd \
    xz-utils \
    numactl \
    net-tools \
    ncat \
    debsums \
    locales \
    tzdata \
    ca-certificates \
    etcd-server \
    etcd-client"
ENV PKG_DEPS=$PKG_DEPS

# Percona PostgreSQL 依赖包
ARG PPG_DEPS="\
    percona-ppg-server-${PG_MAJOR} \
    percona-pgbackrest \
    percona-pgbouncer \
    percona-postgresql-${PG_MAJOR}-pgvector \
    percona-pgbadger"
ENV PPG_DEPS=$PPG_DEPS

# TimescaleDB 依赖包(lite 默认不装 recommends, 显式安装 timescaledb-tools 提供 timescaledb-tune)
ARG TB_DEPS="\
    timescaledb-2-loader-postgresql-${PG_MAJOR} \
    timescaledb-2-postgresql-${PG_MAJOR} \
    timescaledb-tools"
ENV TB_DEPS=$TB_DEPS

# ***** 拷贝构建产物: apt 源 + 密钥 *****
COPY --from=builder /out/keyrings/ /usr/share/keyrings/
COPY --from=builder /out/sources/  /etc/apt/sources.list.d/

# ***** 安装运行依赖 + Percona PostgreSQL + TimescaleDB *****
RUN set -eux && \
    apt-get update -qqy && \
    apt-get install -qqy --no-install-recommends $PKG_DEPS $PPG_DEPS $TB_DEPS --option=Dpkg::Options::=--force-confdef && \
    # 逐个校验依赖包是否安装成功
    for pkg in $PKG_DEPS $PPG_DEPS $TB_DEPS; do \
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then \
            echo "ERROR: 依赖包未成功安装: $pkg" >&2 && exit 1; \
        fi; \
    done && \
    echo "所有依赖包验证通过" && \
    apt-get -qqy autoremove --purge && \
    apt-get -qqy autoclean && \
    # 时区
    ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime && \
    echo ${TZ} > /etc/timezone && \
    # locale: zh_CN.UTF-8 + en_US.UTF-8(兼容 Percona Operator)
    sed -i -e 's/^# *\(zh_CN.UTF-8 UTF-8\)/\1/' -e 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen && \
    locale-gen zh_CN.UTF-8 en_US.UTF-8 && \
    # sudo 权限(PostgreSQL 运行用户需要特定权限)
    sed -i 's/^Defaults.*.requiretty/#Defaults    requiretty/' /etc/sudoers && \
    sed -i '$a\postgres  ALL=(ALL)  NOPASSWD:/bin/mkdir,/bin/chmod,/bin/chown,/usr/bin/psql,/usr/bin/pg_dump' /etc/sudoers && \
    # Percona Operator 硬编码 LD_PRELOAD=/usr/lib64/libnss_wrapper.so(RHEL 路径),
    # Ubuntu 装在 /usr/lib/<arch>/ 下, 需软链接以消除 LD_PRELOAD 加载失败告警
    mkdir -p /usr/lib64 && \
    NSS_WRAPPER_LIB="$(find /usr/lib -name 'libnss_wrapper.so' 2>/dev/null | head -1)" && \
    test -n "${NSS_WRAPPER_LIB}" && \
    ln -sf "${NSS_WRAPPER_LIB}" /usr/lib64/libnss_wrapper.so && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /usr/share/man/*

# ***** 拷贝构建产物: gosu + Patroni venv *****
COPY --from=builder /out/gosu /usr/local/bin/gosu
COPY --from=builder ${PATRONI_HOME} ${PATRONI_HOME}

# ***** Patroni 命令软链到 /usr/local/bin(与旧版 pip 全局安装路径一致) + 自检 *****
RUN set -eux && \
    for bin in patroni patronictl patroni_raft_controller patroni_wale_restore patroni_aws patroni_barman; do \
        [ -x "${PATRONI_HOME}/bin/${bin}" ] && ln -sf "${PATRONI_HOME}/bin/${bin}" /usr/local/bin/${bin} || true; \
    done && \
    gosu --version && \
    gosu nobody true && \
    patroni --version && \
    patronictl version && \
    postgres --version && \
    pgbackrest version && \
    pgbouncer --version && \
    etcd --version && \
    etcdctl version && \
    python3 -c 'import yaml; print("PyYAML", yaml.__version__)' && \
    test -f /usr/lib/postgresql/${PG_MAJOR}/lib/timescaledb.so && \
    test -f /usr/lib/postgresql/${PG_MAJOR}/lib/pg_stat_monitor.so && \
    test -f /usr/lib/postgresql/${PG_MAJOR}/lib/vector.so

# ***** 配置 postgres 用户与目录 *****
RUN set -eux && \
    # 关键：对齐 Percona Operator 官方镜像，postgres 用户固定为 UID/GID=26。
    # Percona Operator 的所有工作负载（database 主进程 + pgBackRest sidecar）
    # 均以 UID 26 运行。若 postgres 用 UID 999，则 sidecar(26) 无法读取数据文件
    # (600/700 权限)，备份必然失败。UID 26 是 Crunchy/Percona 硬编码值
    # (源自 RHEL 的 postgres 系统 UID)，让数据文件属主 = sidecar UID，备份直接可读。
    # 同时 peer 认证时 OS 用户名 postgres 匹配数据库 postgres 角色，无需额外角色。
    # 先清理包安装可能创建的 postgres 用户/组，以及 Ubuntu 默认占用 GID 26 的 tape 组。
    if id postgres > /dev/null 2>&1; then userdel -r postgres 2>/dev/null || userdel postgres; fi && \
    if getent group postgres > /dev/null 2>&1; then groupdel postgres 2>/dev/null || true; fi && \
    if getent passwd 26 > /dev/null 2>&1; then userdel -r $(getent passwd 26 | cut -d: -f1) 2>/dev/null || true; fi && \
    if getent group 26 > /dev/null 2>&1; then groupdel $(getent group 26 | cut -d: -f1) 2>/dev/null || true; fi && \
    groupadd -r postgres --gid=26 && \
    useradd -r -g postgres --uid=26 --home-dir=${PGHOME} --shell=/bin/bash postgres && \
    # 开放 /etc/passwd 可写，兼容 Operator 通过 nss_wrapper 动态注入用户名的场景
    chmod g+w /etc/passwd /etc/group && \
    # 创建目录结构
    mkdir -p /docker-entrypoint-initdb.d && \
    mkdir -m u=rwx,g=rwx,o= -p $PGHOME/data $PGHOME/logs $PGHOME/run $PGHOME/archive /var/run/postgresql /var/log/postgresql && \
    chown -R postgres:postgres $PGHOME /var/run/postgresql /var/log/postgresql /docker-entrypoint-initdb.d && \
    # 清空 Percona 包默认的 /etc/pgbackrest.conf（兼容 Percona Operator）
    # 原因1：包默认权限 640 (UID 100, GID 103)，postgres 用户无权读取导致 stanza-create 失败。
    # 原因2：包默认含 repo1-path，与 Operator 动态注入的 conf.d 配置冲突（repo1-path 重复定义）。
    # Operator 通过 /etc/pgbackrest/conf.d/ 完全管理配置，此处仅置空并开放读权限。
    printf '# Managed by Percona Operator via /etc/pgbackrest/conf.d/\n' > /etc/pgbackrest.conf && \
    chmod 644 /etc/pgbackrest.conf && \
    if [ -d /etc/pgbackrest ]; then chown -R postgres:postgres /etc/pgbackrest; fi && \
    chmod -R 755 $PGHOME /var/run/postgresql /var/log/postgresql && \
    # 移除默认集群配置（避免自动创建）
    sed -ri 's/#(create_main_cluster) .*$/\1 = false/' /etc/postgresql-common/createcluster.conf && \
    # 删除系统自带的 PG 配置目录
    rm -rf /etc/postgresql/${PG_MAJOR}/main/*.conf /var/lib/postgresql && \
    # 修改默认 listen_addresses 为 '*'（容器环境）
    sed -i "/listen_addresses/c listen_addresses ='*'" /usr/share/postgresql/${PG_MAJOR}/postgresql.conf.sample

# ***** 拷贝脚本文件 *****
COPY --chmod=755 ["scripts/docker-entrypoint.sh", "/docker-entrypoint.sh"]
COPY --chmod=755 ["scripts/postgresql-config-tuner.sh", "/usr/local/bin/postgresql-config-tuner.sh"]
# 集群模式（3 节点 etcd + Patroni）：入口、配置渲染脚本与模板
COPY --chmod=755 ["scripts/cluster-entrypoint.sh", "/usr/local/bin/cluster-entrypoint.sh"]
COPY --chmod=755 ["scripts/render-patroni-config.py", "/usr/local/bin/render-patroni-config.py"]
COPY ["conf/patroni/patroni.yml.tmpl", "/etc/patroni/patroni.yml.tmpl"]

RUN chown postgres:postgres /docker-entrypoint.sh /usr/local/bin/postgresql-config-tuner.sh \
        /usr/local/bin/cluster-entrypoint.sh /usr/local/bin/render-patroni-config.py && \
    chmod -R 755 /etc/patroni && chown -R postgres:postgres /etc/patroni

# ***** 容器信号处理 *****
STOPSIGNAL SIGQUIT

# ***** 工作目录 *****
WORKDIR ${PGHOME}

# ***** 挂载目录 *****
VOLUME ${PGHOME}

# ***** 入口 *****
ENTRYPOINT ["/docker-entrypoint.sh"]

# ***** 监听端口 *****
#   5432 PostgreSQL / 8008 Patroni REST API / 2379-2380 etcd(集群模式)
EXPOSE 5432 8008 2379 2380

# ***** 用户 *****
USER 26

# ***** 执行命令 *****
CMD ["postgres"]
