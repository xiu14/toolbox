#!/bin/bash
set -euo pipefail

# ─── 配置项（可直接改这里，或留空走交互）─────────────────────────
ST_DIR="$HOME/SillyTavern"
ST_REPO="https://github.com/SillyTavern/SillyTavern.git"
ST_BRANCH="release"          # 或 main
VERSION_MODE=""              # latest 或 tag；留空走交互
VERSION_TAG=""               # VERSION_MODE=tag 时可直接指定，例如 1.12.0
VERSION_LIMIT="20"           # 选择版本时显示最近多少个 tag

PORT=""
USERNAME=""
PASSWORD=""
PM2_NAME="sillytavern"
REQUESTED_ACTION=""
ASSUME_YES="false"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")"
# ──────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
用法：
  $0                 显示操作菜单
  $0 --clean         清除部署产物后退出（保留本脚本）
  $0 --clean --yes   不确认，直接清除（用于反复测试）
  $0 --help          显示帮助

清除范围：
  - PM2 中的 $PM2_NAME 进程和保存状态
  - PM2 daemon、PM2 日志和 $HOME/.pm2
  - npm 全局安装的 pm2
  - npm 缓存目录 $HOME/.npm
  - $ST_DIR
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --clean|clean)
        REQUESTED_ACTION="clean"
        ;;
      --yes|-y)
        ASSUME_YES="true"
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "错误：未知参数：$1" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift
  done
}

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo > /dev/null 2>&1; then
    sudo "$@"
  else
    echo "错误：安装依赖需要 root 权限或 sudo。" >&2
    exit 1
  fi
}

select_action() {
  local choice

  echo "请选择操作："
  echo "  1) 部署 / 更新 SillyTavern"
  echo "  2) 清除部署产物后退出"
  echo "  3) 清除后重新部署（反复测试用）"
  read -rp "请输入选项 [1]: " choice

  case "${choice:-1}" in
    1)
      REQUESTED_ACTION="deploy"
      ;;
    2)
      REQUESTED_ACTION="clean"
      ;;
    3)
      REQUESTED_ACTION="clean-deploy"
      ;;
    *)
      echo "错误：无效选项。" >&2
      exit 1
      ;;
  esac
}

assert_can_remove_path() {
  local target="$1"
  local resolved_target

  resolved_target="$(readlink -f "$target" 2>/dev/null || printf '%s\n' "$target")"

  case "$resolved_target" in
    ''|'/')
      echo "错误：拒绝删除危险路径：$target" >&2
      exit 1
      ;;
  esac

  case "$SCRIPT_PATH" in
    "$resolved_target"|"$resolved_target"/*)
      echo "错误：清除目录包含脚本本身，拒绝删除：$target" >&2
      exit 1
      ;;
  esac
}

confirm_clean() {
  local answer

  if [ "$ASSUME_YES" = "true" ]; then
    return 0
  fi

  echo "将清除 SillyTavern 部署产物，保留本脚本：$0"
  echo "清除目录：$ST_DIR"
  echo "清除 PM2：进程 $PM2_NAME、保存状态、$HOME/.pm2、全局 pm2 包"
  echo "清除缓存：$HOME/.npm"
  echo "不会卸载 git、nodejs、npm 等系统依赖。"
  read -rp "确认清除？请输入 yes 继续: " answer

  if [ "$answer" != "yes" ]; then
    echo "已取消清除。"
    exit 0
  fi
}

clean_deployment() {
  echo "=== SillyTavern 清除模式 ==="
  confirm_clean

  if command -v pm2 > /dev/null 2>&1; then
    echo "[1/4] 停止并删除 PM2 进程..."
    pm2 delete "$PM2_NAME" > /dev/null 2>&1 || true
    pm2 save --force > /dev/null 2>&1 || true
    pm2 kill > /dev/null 2>&1 || true
  else
    echo "[1/4] 未检测到 PM2，跳过进程清理。"
  fi

  echo "[2/4] 删除 SillyTavern 目录..."
  if [ -n "$ST_DIR" ] && [ "$ST_DIR" != "/" ] && [ -e "$ST_DIR" ]; then
    assert_can_remove_path "$ST_DIR"
    rm -rf "$ST_DIR"
  fi

  echo "[3/4] 删除 PM2 和 npm 数据目录..."
  if [ -n "${HOME:-}" ] && [ -d "$HOME/.pm2" ]; then
    assert_can_remove_path "$HOME/.pm2"
    rm -rf "$HOME/.pm2"
  fi
  if [ -n "${HOME:-}" ] && [ -d "$HOME/.npm" ]; then
    assert_can_remove_path "$HOME/.npm"
    rm -rf "$HOME/.npm"
  fi

  if command -v npm > /dev/null 2>&1; then
    echo "[4/4] 卸载 npm 全局 PM2..."
    run_as_root npm uninstall -g pm2 > /dev/null 2>&1 || true
  else
    echo "[4/4] 未检测到 npm，跳过 PM2 全局包卸载。"
  fi

  echo ""
  echo "清除完成。本脚本已保留：$0"
}

install_apt_packages() {
  local packages=("$@")
  [ "${#packages[@]}" -eq 0 ] && return 0

  if ! command -v apt-get > /dev/null 2>&1; then
    echo "错误：缺少系统依赖：${packages[*]}，且当前系统没有 apt-get，请手动安装后重试。" >&2
    exit 1
  fi

  echo "检测到缺少系统依赖：${packages[*]}，正在安装..."
  run_as_root apt-get update
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
}

ensure_base_dependencies() {
  local apt_packages=()
  local missing=()
  local cmd

  command -v git > /dev/null 2>&1 || apt_packages+=(git)
  command -v python3 > /dev/null 2>&1 || apt_packages+=(python3)

  if ! command -v node > /dev/null 2>&1 || ! command -v npm > /dev/null 2>&1; then
    apt_packages+=(nodejs npm)
  fi

  install_apt_packages "${apt_packages[@]}"

  for cmd in git node npm python3; do
    command -v "$cmd" > /dev/null 2>&1 || missing+=("$cmd")
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "错误：以下命令仍不可用：${missing[*]}，请检查安装结果后重试。" >&2
    exit 1
  fi
}

ensure_pm2() {
  if ! command -v pm2 > /dev/null 2>&1; then
    echo "检测到缺少 PM2，正在通过 npm 全局安装..."
    run_as_root npm install -g pm2
  fi

  if ! command -v pm2 > /dev/null 2>&1; then
    echo "错误：PM2 安装后仍不可用，请检查 npm 全局安装路径。" >&2
    exit 1
  fi
}

ask() {
  local var="$1" prompt="$2" default="$3"
  if [ -z "${!var}" ]; then
    read -rp "$prompt${default:+ [$default]}: " val
    printf -v "$var" '%s' "${val:-$default}"
  fi
}

ask_secret_required() {
  local var="$1" prompt="$2" val
  if [ -z "${!var}" ]; then
    while true; do
      read -rsp "$prompt: " val
      echo
      if [ -n "$val" ]; then
        printf -v "$var" '%s' "$val"
        break
      fi
      echo "密码不能为空，请重新输入。"
    done
  fi
}

validate_port() {
  case "$PORT" in
    ''|*[!0-9]*)
      echo "错误：监听端口必须是数字。" >&2
      exit 1
      ;;
  esac

  if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "错误：监听端口必须在 1-65535 之间。" >&2
    exit 1
  fi
}

validate_version_limit() {
  case "$VERSION_LIMIT" in
    ''|*[!0-9]*)
      echo "错误：VERSION_LIMIT 必须是数字。" >&2
      exit 1
      ;;
  esac

  if [ "$VERSION_LIMIT" -lt 1 ]; then
    echo "错误：VERSION_LIMIT 必须大于 0。" >&2
    exit 1
  fi
}

select_deploy_ref() {
  local choice tags_output tag_choice i

  validate_version_limit

  if [ -z "$VERSION_MODE" ]; then
    echo "请选择拉取方式："
    echo "  1) 直接拉取最新版本（$ST_BRANCH 分支）"
    echo "  2) 从可拉取版本中选择（Git tag）"
    read -rp "请输入选项 [1]: " choice
    case "${choice:-1}" in
      1) VERSION_MODE="latest" ;;
      2) VERSION_MODE="tag" ;;
      *)
        echo "错误：无效选项。" >&2
        exit 1
        ;;
    esac
  fi

  case "$VERSION_MODE" in
    latest)
      ST_REF_TYPE="branch"
      ST_REF="$ST_BRANCH"
      ;;
    tag)
      ST_REF_TYPE="tag"
      if [ -z "$VERSION_TAG" ]; then
        echo "正在获取可拉取版本列表..."
        if ! tags_output="$(git ls-remote --tags --refs --sort=-v:refname "$ST_REPO" "refs/tags/*" 2>/dev/null)"; then
          tags_output="$(git ls-remote --tags --refs "$ST_REPO" "refs/tags/*")" || {
            echo "错误：获取远端版本列表失败，请检查网络或仓库地址。" >&2
            exit 1
          }
        fi

        mapfile -t REMOTE_TAGS < <(printf '%s\n' "$tags_output" | sed 's#.*refs/tags/##' | head -n "$VERSION_LIMIT")

        if [ "${#REMOTE_TAGS[@]}" -eq 0 ]; then
          echo "错误：没有找到可拉取的 tag 版本。" >&2
          exit 1
        fi

        echo "可拉取版本："
        for i in "${!REMOTE_TAGS[@]}"; do
          printf "  %2d) %s\n" "$((i + 1))" "${REMOTE_TAGS[$i]}"
        done

        while true; do
          read -rp "请选择版本序号 [1]: " tag_choice
          tag_choice="${tag_choice:-1}"
          case "$tag_choice" in
            ''|*[!0-9]*)
              echo "请输入数字序号。"
              ;;
            *)
              if [ "$tag_choice" -ge 1 ] && [ "$tag_choice" -le "${#REMOTE_TAGS[@]}" ]; then
                VERSION_TAG="${REMOTE_TAGS[$((tag_choice - 1))]}"
                break
              fi
              echo "序号超出范围。"
              ;;
          esac
        done
      fi
      ST_REF="$VERSION_TAG"
      ;;
    *)
      echo "错误：VERSION_MODE 只能是 latest 或 tag。" >&2
      exit 1
      ;;
  esac
}

parse_args "$@"

echo "=== SillyTavern 一键部署脚本 ==="

if [ -z "$REQUESTED_ACTION" ]; then
  select_action
fi

case "$REQUESTED_ACTION" in
  clean)
    clean_deployment
    exit 0
    ;;
  clean-deploy)
    clean_deployment
    ;;
  deploy)
    ;;
  *)
    echo "错误：未知操作：$REQUESTED_ACTION" >&2
    exit 1
    ;;
esac

ensure_base_dependencies
select_deploy_ref
ask PORT     "监听端口"    "8000"
ask USERNAME "Basic Auth 用户名" "admin"
ask_secret_required PASSWORD "Basic Auth 密码"
validate_port

# 1. 拉取 / 更新
if [ -d "$ST_DIR/.git" ]; then
  echo "[1/4] 更新仓库..."
  if [ "$ST_REF_TYPE" = "branch" ]; then
    git -C "$ST_DIR" fetch origin "$ST_REF"
    git -C "$ST_DIR" checkout "$ST_REF"
    git -C "$ST_DIR" pull --ff-only
  else
    git -C "$ST_DIR" fetch --tags origin
    git -C "$ST_DIR" checkout --detach "$ST_REF"
  fi
else
  echo "[1/4] 克隆仓库..."
  git clone --branch "$ST_REF" --depth 1 "$ST_REPO" "$ST_DIR"
fi

# 2. 安装依赖
echo "[2/4] 安装 npm 依赖..."
cd "$ST_DIR"
npm install --no-audit --no-fund

# 3. 修改 config.yaml
echo "[3/4] 写入配置..."
CONFIG="$ST_DIR/config.yaml"

# 如果 config.yaml 不存在，从模板复制
[ -f "$CONFIG" ] || cp "$ST_DIR/default/config.yaml" "$CONFIG"

export CONFIG PORT USERNAME PASSWORD
python3 - <<'PYEOF'
import json
import os
import re

path = os.environ["CONFIG"]

with open(path, encoding="utf-8") as f:
    txt = f.read()


def yaml_string(value):
    # JSON string syntax is valid YAML and safely handles quotes, colons, #, etc.
    return json.dumps(value)


def set_top_level(text, key, value):
    pattern = re.compile(rf"^({re.escape(key)}:\s*).*$", re.MULTILINE)
    replacement = rf"\g<1>{value}"
    if pattern.search(text):
        return pattern.sub(replacement, text, count=1)
    return text.rstrip() + f"\n{key}: {value}\n"


def set_mapping(text, key, values):
    block = [f"{key}:"]
    block.extend(f"  {child}: {value}" for child, value in values.items())
    block_text = "\n".join(block)

    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if re.match(rf"^{re.escape(key)}:\s*(?:#.*)?$", line):
            start = i
            break

    if start is None:
        return text.rstrip() + "\n" + block_text + "\n"

    end = start + 1
    while end < len(lines):
        line = lines[end]
        if line and not line.startswith((" ", "\t")):
            break
        end += 1

    lines[start:end] = block
    trailing_newline = "\n" if text.endswith("\n") else ""
    return "\n".join(lines) + trailing_newline


txt = set_top_level(txt, "port", os.environ["PORT"])
txt = set_top_level(txt, "listen", "true")
txt = set_top_level(txt, "whitelistMode", "false")
txt = set_top_level(txt, "basicAuthMode", "true")
txt = set_mapping(
    txt,
    "basicAuthUser",
    {
        "username": yaml_string(os.environ["USERNAME"]),
        "password": yaml_string(os.environ["PASSWORD"]),
    },
)

with open(path, "w", encoding="utf-8") as f:
    f.write(txt)

os.chmod(path, 0o600)

print("config.yaml 写入完成：公网监听已开启，IP 白名单已关闭，Basic Auth 已开启。")
PYEOF

# 4. PM2
echo "[4/4] 配置 PM2..."
ensure_pm2

# 如果已存在同名进程则重启，否则新建
if pm2 describe "$PM2_NAME" > /dev/null 2>&1; then
  pm2 restart "$PM2_NAME"
else
  pm2 start "$ST_DIR/server.js" \
    --name "$PM2_NAME" \
    --cwd "$ST_DIR"
fi

pm2 save

echo ""
echo "✅ 部署完成！"
echo "   地址：http://0.0.0.0:$PORT"
echo "   用户：$USERNAME"
echo "   版本：$ST_REF_TYPE $ST_REF"
echo "   PM2：pm2 logs $PM2_NAME"
