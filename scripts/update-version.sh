#!/usr/bin/env bash
#=================================================
# https://github.com/iflyelf/postgres-docker
# 同步 Dockerfile 中的组件版本号(GitHub API 最新稳定 release)
#
# 纳入自动更新:
#   GOSU_VERSION     <- tianon/gosu
#   PATRONI_VERSION  <- patroni/patroni
#
# 不纳入自动更新:
#   PG_MAJOR  跨大版本升级需 pg_upgrade 迁移数据目录, 必须人工评估
#   PostgreSQL 小版本 / TimescaleDB / pgvector 等由 apt 源在构建时自动取最新
#
# 用法:
#   GH_TOKEN=xxx bash scripts/update-version.sh   # GH_TOKEN 可选, 用于提高 API 限额
#
# 在 GitHub Actions 中会额外写入 $GITHUB_ENV:
#   CHANGED=0|1        是否有改动
#   SUMMARY=...        改动摘要(用于 commit message)
#=================================================
set -euo pipefail

DOCKERFILE="${DOCKERFILE:-Dockerfile}"

# ---------- 稳定版过滤: 排除 rc/beta/alpha/test/dev/preview/snapshot ----------
is_stable() {
    echo "$1" | grep -qivE '(rc|beta|alpha|test|dev|preview|snapshot|nightly|-pre|m[0-9])'
}

# ---------- 语义化版本比较: 若 $1 > $2 返回 0 ----------
version_gt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

# ---------- GitHub API 请求(有 token 时带上认证) ----------
gh_api() {
    if [ -n "${GH_TOKEN:-}" ]; then
        curl -fsSL -H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json" "$1"
    else
        curl -fsSL -H "Accept: application/vnd.github+json" "$1"
    fi
}

# ---------- 取 GitHub 仓库最新稳定版本(去掉前缀 v), 失败返回空 ----------
# 优先 releases(排除 prerelease/draft), 为空时回退到 tags(仅纯数字版本)
gh_latest_stable() {
    local repo="$1" out
    out=$({ gh_api "https://api.github.com/repos/${repo}/releases?per_page=50" 2>/dev/null || true; } \
        | { jq -r '.[] | select(.prerelease==false and .draft==false) | .tag_name' 2>/dev/null || true; } \
        | sed 's/^v//' \
        | while read -r t; do is_stable "$t" && echo "$t"; done \
        | grep -E '^[0-9]+(\.[0-9]+)+$' \
        | sort -V | tail -1 || true)
    if [ -z "$out" ]; then
        out=$({ gh_api "https://api.github.com/repos/${repo}/tags?per_page=50" 2>/dev/null || true; } \
            | { jq -r '.[].name' 2>/dev/null || true; } \
            | sed 's/^v//' \
            | grep -E '^[0-9]+(\.[0-9]+)+$' \
            | sort -V | tail -1 || true)
    fi
    echo "$out"
}

CHANGED=0
SUMMARY=""

# ---------- 通用更新函数: $1=ARG名 $2=最新版本 ----------
try_update() {
    local arg="$1" latest="$2" current
    [ -z "$latest" ] && { echo "  [$arg] 获取最新版本失败, 跳过"; return 0; }
    current=$(grep -oP "^ARG ${arg}=\K.*" "$DOCKERFILE" | head -1 || true)
    [ -z "$current" ] && { echo "  [$arg] Dockerfile 中未找到, 跳过"; return 0; }
    if [ "$current" = "$latest" ]; then
        echo "  [$arg] 已是最新 ($current)"
    elif version_gt "$latest" "$current"; then
        echo "  [$arg] 更新: $current => $latest"
        sed -i "s|^ARG ${arg}=.*|ARG ${arg}=${latest}|" "$DOCKERFILE"
        CHANGED=1
        SUMMARY="${SUMMARY}\n- ${arg}: ${current} => ${latest}"
    else
        echo "  [$arg] 远程版本($latest)不高于当前($current), 跳过"
    fi
}

echo "===== 检查组件版本(GitHub API, 仅稳定 release) ====="
try_update GOSU_VERSION    "$(gh_latest_stable tianon/gosu)"
try_update PATRONI_VERSION "$(gh_latest_stable patroni/patroni)"

echo ""
if [ "$CHANGED" = "1" ]; then
    echo "检测到版本更新:"
    echo -e "$SUMMARY"
else
    echo "所有版本均为最新, 无需更新"
fi

# 写入 GitHub Actions 环境(本地执行时跳过)
if [ -n "${GITHUB_ENV:-}" ]; then
    {
        echo "CHANGED=${CHANGED}"
        echo "SUMMARY<<EOF"
        echo -e "$SUMMARY"
        echo "EOF"
    } >> "$GITHUB_ENV"
fi
