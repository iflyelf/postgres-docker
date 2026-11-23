#!/usr/bin/env python3
# ==================================================
# 渲染 Patroni 配置（集群模式）
#
# 流程：
#   1. 读取模板 conf/patroni/patroni.yml.tmpl，替换 __VAR__ 占位符（来自环境变量）
#   2. 若 CLUSTER_AUTOTUNE 不为 false，则调用 postgresql-config-tuner.sh json
#      把自动调优参数合并进 postgresql.parameters（模板已显式指定的键不覆盖）
#   3. 输出最终 Patroni 配置
#
# 用法：
#   render-patroni-config.py --template /etc/patroni/patroni.yml.tmpl --output /tmp/patroni.yml
# ==================================================
import argparse
import json
import os
import re
import subprocess
import sys

TUNER = os.environ.get("TUNER", "/usr/local/bin/postgresql-config-tuner.sh")
PLACEHOLDER = re.compile(r"__([A-Z0-9_]+)__")


def render_placeholders(text: str) -> str:
    missing = []

    def repl(match):
        key = match.group(1)
        value = os.environ.get(key)
        if value is None:
            missing.append(key)
            return ""
        return value

    rendered = PLACEHOLDER.sub(repl, text)
    if missing:
        raise SystemExit("ERROR: 模板占位符缺少对应环境变量: " + ", ".join(sorted(set(missing))))
    return rendered


def load_yaml(stream):
    try:
        import yaml
    except ImportError:  # 运行镜像内由 python3-yaml 提供
        raise SystemExit("ERROR: 缺少 PyYAML，请在镜像中安装 python3-yaml")
    return yaml.safe_load(stream)


def dump_yaml(data) -> str:
    import yaml
    return yaml.safe_dump(data, allow_unicode=True, sort_keys=False, default_flow_style=False)


def normalize(value):
    """把 JSON 中的数值规范为字符串，便于写入 postgresql.conf 与 Patroni 比较"""
    if isinstance(value, bool):
        return "on" if value else "off"
    if isinstance(value, (int, float)):
        return str(value)
    return value


def tuner_parameters() -> dict:
    """调用调优脚本获取 JSON 参数；失败时返回空字典（集群仍可启动）"""
    if os.environ.get("CLUSTER_AUTOTUNE", "true").lower() in ("false", "0", "no"):
        print(">>> [render] CLUSTER_AUTOTUNE=false，跳过自动调优参数合并")
        return {}
    try:
        out = subprocess.run([TUNER, "json"], check=True, capture_output=True, text=True).stdout
        params = {k: normalize(v) for k, v in json.loads(out).items()}
        print(f">>> [render] 自动调优参数 {len(params)} 项（内存 {os.environ.get('PG_MEMORY_LIMIT', '自动探测')}"
              f" / CPU {os.environ.get('PG_CPU_LIMIT', '自动探测')}）")
        return params
    except Exception as exc:  # noqa: BLE001 - 调优失败不应阻断集群启动
        print(f">>> [render] WARNING: 自动调优参数获取失败（{exc}），使用模板参数", file=sys.stderr)
        return {}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    with open(args.template, encoding="utf-8") as fh:
        template_text = render_placeholders(fh.read())

    config = load_yaml(template_text)
    if not isinstance(config, dict):
        raise SystemExit("ERROR: 模板渲染后不是合法 YAML 映射")

    auto = tuner_parameters()
    if auto:
        pg = config.setdefault("postgresql", {})
        params = pg.setdefault("parameters", {}) or {}
        # 模板中显式配置的项优先，自动调优只补缺
        added = 0
        for key, value in auto.items():
            if key not in params:
                params[key] = value
                added += 1
        pg["parameters"] = params
        # DCS 侧同步一份，便于 patronictl 查看与后续扩缩容（同样不覆盖已有项）
        bootstrap = config.setdefault("bootstrap", {})
        dcs = bootstrap.setdefault("dcs", {})
        dcs_pg = dcs.setdefault("postgresql", {})
        dcs_params = dcs_pg.setdefault("parameters", {}) or {}
        for key, value in auto.items():
            dcs_params.setdefault(key, value)
        dcs_pg["parameters"] = dcs_params
        print(f">>> [render] 合并自动调优参数 {added} 项到 postgresql.parameters")

    with open(args.output, "w", encoding="utf-8") as fh:
        fh.write(dump_yaml(config))
    # Patroni 以 postgres 用户运行，需可读
    os.chmod(args.output, 0o640)
    print(f">>> [render] 已生成 {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
