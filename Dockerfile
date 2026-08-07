#############################
#     设置公共的变量         #
#############################
ARG BASE_IMAGE_TAG=resolute
FROM ubuntu:${BASE_IMAGE_TAG}

# 作者描述信息
LABEL org.opencontainers.image.authors="iflyelf" \
      org.opencontainers.image.vendor="iflyelf"

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
ARG DOCKER_IMAGE_TAG=resolute
ENV DOCKER_IMAGE_TAG=$DOCKER_IMAGE_TAG

# 环境设置
ARG DEBIAN_FRONTEND=noninteractive
ENV DEBIAN_FRONTEND=$DEBIAN_FRONTEND

# PG 版本号（TimescaleDB 当前支持到 PG 17，保持最新可用组合）
ARG PG_MAJOR=17
ENV PG_MAJOR=$PG_MAJOR
ENV PATH=$PATH:/usr/lib/postgresql/$PG_MAJOR/bin

# 工作目录
ARG PGHOME=/data/postgres
ENV PGHOME=$PGHOME
# 数据目录
ARG PGDATA=/data/postgres/data
ENV PGDATA=$PGDATA

# 源文件下载路径
ARG DOWNLOAD_SRC=/tmp
ENV DOWNLOAD_SRC=$DOWNLOAD_SRC

# 系统基础依赖包
ARG PKG_DEPS="\
    zsh \
    bash \
    bash-completion \
    sudo \
    bind9-dnsutils \
    iproute2 \
    net-tools \
    ncat \
    git \
    vim \
    tzdata \
    curl \
    wget \
    axel \
    lsof \
    zip \
    unzip \
    rsync \
    iputils-ping \
    telnet \
    procps \
    numactl \
    xz-utils \
    zstd \
    libnss-wrapper \
    gnupg2 \
    psmisc \
    debsums \
    locales \
    language-pack-zh-hans \
    lsb-release \
    libpq5 \
    ssl-cert \
    libdbd-pg-perl \
    libdbi-perl \
    perl-modules \
    python3 \
    python3-pip \
    python3-yaml \
    python3-psycopg2 \
    ca-certificates"
ENV PKG_DEPS=$PKG_DEPS

# Percona PostgreSQL 依赖包
ARG PPG_DEPS="\
    percona-ppg-server-${PG_MAJOR} \
    percona-pgbackrest \
    percona-pgbouncer \
    percona-postgresql-${PG_MAJOR}-pgvector \
    percona-pgbadger"
ENV PPG_DEPS=$PPG_DEPS

# TimescaleDB 依赖包
ARG TB_DEPS="\
    timescaledb-2-loader-postgresql-${PG_MAJOR} \
    timescaledb-2-postgresql-${PG_MAJOR}"
ENV TB_DEPS=$TB_DEPS

# Patroni（通过 pip 安装最新版本，兼容 Percona Operator）
ARG PATRONI_DEPS="\
    patroni[psycopg3] \
    python-json-logger"
ENV PATRONI_DEPS=$PATRONI_DEPS

# ***** 安装依赖 *****
RUN set -eux && \
   # 更新源地址（deb822 格式，适配 Ubuntu 24.04+）
   sed -i 's@URIs: http://[a-z.]*\.ubuntu\.com/ubuntu/@URIs: https://mirrors.aliyun.com/ubuntu/@g' /etc/apt/sources.list.d/ubuntu.sources && \
   sed -i 's@^Types: deb$@Types: deb deb-src@' /etc/apt/sources.list.d/ubuntu.sources && \
   # 解决证书认证失败问题
   touch /etc/apt/apt.conf.d/99verify-peer.conf && echo >>/etc/apt/apt.conf.d/99verify-peer.conf "Acquire { https::Verify-Peer false }" && \
   # 更新系统软件
   DEBIAN_FRONTEND=noninteractive apt-get update -qqy && apt-get upgrade -qqy && \
   # 安装系统依赖包
   DEBIAN_FRONTEND=noninteractive apt-get install -qqy --no-install-recommends $PKG_DEPS --option=Dpkg::Options::=--force-confdef && \
   DEBIAN_FRONTEND=noninteractive apt-get -qqy --no-install-recommends autoremove --purge && \
   DEBIAN_FRONTEND=noninteractive apt-get -qqy --no-install-recommends autoclean && \
   rm -rf /var/lib/apt/lists/* && \
   # 更新时区
   ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime && \
   echo ${TZ} > /etc/timezone && \
   # sudo 权限（PostgreSQL 运行用户需要特定权限）
   sed -i 's/^Defaults.*.requiretty/#Defaults    requiretty/' /etc/sudoers && \
   sed -i '$a\postgres  ALL=(ALL)  NOPASSWD:/bin/mkdir,/bin/chmod,/bin/chown,/usr/bin/psql,/usr/bin/pg_dump' /etc/sudoers && \
   # 更改为 zsh
   sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" || true && \
   sed -i -e "s/bin\/ash/bin\/zsh/" /etc/passwd && \
   # vim 默认配置文件存在时才关闭 mouse（不同版本路径不同，用 find 定位）
   find /usr/share/vim -name defaults.vim -exec sed -i -e 's/mouse=/mouse-=/g' {} + && \
   # 配置 locale（生成 zh_CN.UTF-8 和 en_US.UTF-8，兼容 Percona Operator）
   locale-gen zh_CN.UTF-8 && localedef -f UTF-8 -i zh_CN zh_CN.UTF-8 && \
   locale-gen en_US.UTF-8 && localedef -f UTF-8 -i en_US en_US.UTF-8 && \
   locale-gen && \
   # 创建 libnss_wrapper.so 软链接到 Operator 期望的 /usr/lib64 路径
   # Percona Operator 硬编码 LD_PRELOAD=/usr/lib64/libnss_wrapper.so（RHEL 路径），
   # 但 Ubuntu 装在 /usr/lib/<arch>/ 下，需软链接以消除 LD_PRELOAD 加载失败告警
   mkdir -p /usr/lib64 && \
   NSS_WRAPPER_LIB="$(find /usr/lib -name 'libnss_wrapper.so' 2>/dev/null | head -1)" && \
   ln -sf "${NSS_WRAPPER_LIB}" /usr/lib64/libnss_wrapper.so

# ***** 安装 Percona PostgreSQL + TimescaleDB *****
RUN set -eux && \
    # 下载并安装 Percona 源
    wget --no-check-certificate https://repo.percona.com/apt/percona-release_latest.$(lsb_release -sc)_all.deb \
         -O ${DOWNLOAD_SRC}/percona-release_latest.$(lsb_release -sc)_all.deb && \
    dpkg -i ${DOWNLOAD_SRC}/percona-release_latest.$(lsb_release -sc)_all.deb && \
    rm ${DOWNLOAD_SRC}/percona-release_latest.$(lsb_release -sc)_all.deb && \
    # 启用 Percona ppg-${PG_MAJOR} 仓库
    percona-release setup ppg-${PG_MAJOR} && \
    # 安装 TimescaleDB 源（从 packagecloud）
    echo "deb https://packagecloud.io/timescale/timescaledb/ubuntu/ $(lsb_release -c -s) main" | tee /etc/apt/sources.list.d/timescaledb.list && \
    wget --quiet -O - https://packagecloud.io/timescale/timescaledb/gpgkey | gpg --dearmor -o /etc/apt/trusted.gpg.d/timescaledb.gpg && \
    # 更新源并安装 Percona PostgreSQL + TimescaleDB
    DEBIAN_FRONTEND=noninteractive apt-get update -qqy && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y $PPG_DEPS && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y $TB_DEPS && \
    # 清理
    DEBIAN_FRONTEND=noninteractive apt-get -qqy --no-install-recommends autoremove --purge && \
    DEBIAN_FRONTEND=noninteractive apt-get -qqy --no-install-recommends autoclean && \
    rm -rf /var/lib/apt/lists/*

# ***** 安装 Patroni（兼容 Percona Operator）*****
RUN set -eux && \
    python3 -m pip config set global.break-system-packages true && \
    pip3 config set global.index-url http://mirrors.aliyun.com/pypi/simple/ && \
    pip3 config set install.trusted-host mirrors.aliyun.com && \
    python3 -m pip install --no-cache-dir $PATRONI_DEPS && \
    rm -rf /tmp/* /var/lib/apt/lists/*

# ***** grab gosu for easy step-down from root *****
# https://github.com/tianon/gosu/releases
ENV GOSU_VERSION=1.17
RUN set -eux && \
    savedAptMark="$(apt-mark showmanual)" && \
    apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates wget && \
    rm -rf /var/lib/apt/lists/* && \
    dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')" && \
    wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch" && \
    wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc" && \
    export GNUPGHOME="$(mktemp -d)" && \
    gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4 && \
    gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu && \
    gpgconf --kill all && \
    rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc && \
    apt-mark auto '.*' > /dev/null && \
    [ -z "$savedAptMark" ] || apt-mark manual $savedAptMark > /dev/null && \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false && \
    chmod +x /usr/local/bin/gosu && \
    gosu --version && \
    gosu nobody true

# ***** 配置 postgres 用户与目录 *****
RUN set -eux && \
    # Percona/PostgreSQL 包安装时可能已创建 postgres 用户/组（UID/GID 不定），
    # 先清理再以固定 UID/GID=999 重建（兼容 Percona Operator 和标准 PG 镜像）
    if id postgres > /dev/null 2>&1; then userdel -r postgres 2>/dev/null || userdel postgres; fi && \
    if getent group postgres > /dev/null 2>&1; then groupdel postgres 2>/dev/null || true; fi && \
    if getent group 999 > /dev/null 2>&1; then groupdel $(getent group 999 | cut -d: -f1) 2>/dev/null || true; fi && \
    groupadd -r postgres --gid=999 && \
    useradd -r -g postgres --uid=999 --home-dir=${PGHOME} --shell=/bin/zsh postgres && \
    # 兼容 Percona Operator 的 pgBackRest sidecar（以 UID 26 运行）
    # 该 sidecar 用同一镜像但直接运行 `pgbackrest server`（不走本镜像 entrypoint），
    # pgBackRest 通过 Unix socket + peer 认证连接 PostgreSQL。peer 认证要求
    # OS 用户名必须匹配数据库角色名。此处创建 UID 26 的 "pgbackrest" 用户，
    # 对应需在 PostgreSQL 里创建 "pgbackrest" 角色（通过 initdb 后的 SQL 或
    # Operator 机制），并在 pg_hba 加 "local all pgbackrest peer"。
    if ! getent group 26 > /dev/null 2>&1; then groupadd -g 26 tape; fi && \
    if ! getent passwd 26 > /dev/null 2>&1; then useradd -u 26 -g 26 --home-dir=${PGHOME} --shell=/bin/bash pgbackrest; fi && \
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
COPY ["scripts/docker-entrypoint.sh", "/docker-entrypoint.sh"]
COPY ["scripts/postgresql-config-tuner.sh", "/usr/local/bin/postgresql-config-tuner.sh"]

RUN chmod +x /docker-entrypoint.sh /usr/local/bin/postgresql-config-tuner.sh && \
    chown postgres:postgres /docker-entrypoint.sh /usr/local/bin/postgresql-config-tuner.sh

# ***** 容器信号处理 *****
STOPSIGNAL SIGQUIT

# ***** 工作目录 *****
WORKDIR ${PGHOME}

# ***** 挂载目录 *****
VOLUME ${PGHOME}

# ***** 入口 *****
ENTRYPOINT ["/docker-entrypoint.sh"]

# ***** 监听端口 *****
EXPOSE 5432 8008

# ***** 用户 *****
USER 999

# ***** 执行命令 *****
CMD ["postgres"]
