#!/bin/bash

GITHUB_USER="xiu14"
GITHUB_REPO="toolbox"
GITHUB_BRANCH="main"
SCRIPTS_DIR="scripts"

BASE_URL="https://raw.githubusercontent.com/$GITHUB_USER/$GITHUB_REPO/$GITHUB_BRANCH/$SCRIPTS_DIR"
API_URL="https://api.github.com/repos/$GITHUB_USER/$GITHUB_REPO/contents/$SCRIPTS_DIR?ref=$GITHUB_BRANCH"
INSTALL_DIR="$HOME"
TTY="/dev/tty"

prompt() {
    local var="$1"
    local text="$2"

    if [ -r "$TTY" ]; then
        read -r -p "$text" "$var" < "$TTY"
    else
        read -r -p "$text" "$var"
    fi
}

# ─── 从 GitHub API 拉取脚本列表 ──────────────────
fetch_scripts() {
    echo "🔍 读取脚本列表..."
    SCRIPT_LIST=$(curl -fsSL "$API_URL" | grep '"name"' | grep '\.sh' | sed 's/.*"name": "\(.*\)".*/\1/')

    if [ -z "$SCRIPT_LIST" ]; then
        echo "❌ 无法读取脚本列表，请检查网络或仓库地址"
        exit 1
    fi

    # 转成数组
    mapfile -t SCRIPTS <<< "$SCRIPT_LIST"
}

# ─── 打印菜单 ────────────────────────────────────
print_menu() {
    echo ""
    echo "╔═══════════════════════════════╗"
    echo "║         我的工具箱            ║"
    echo "╠═══════════════════════════════╣"
    for i in "${!SCRIPTS[@]}"; do
        printf "║  %d. %-27s║\n" "$((i+1))" "${SCRIPTS[$i]}"
    done
    echo "║  a. 全部安装                  ║"
    echo "║  0. 退出                      ║"
    echo "╚═══════════════════════════════╝"
    echo ""
}

# ─── 安装单个脚本 ────────────────────────────────
install_script() {
    local filename="$1"
    local target="$INSTALL_DIR/$filename"

    echo "📥 下载 $filename ..."
    curl -fsSL "$BASE_URL/$filename" -o "$target"

    if [ $? -ne 0 ]; then
        echo "❌ 下载失败：$filename"
        return 1
    fi

    chmod +x "$target"
    if [ "$filename" = "proxy.sh" ]; then
        echo "🔧 初始化 $filename ..."
        if [ -r "$TTY" ]; then
            source "$target" init < "$TTY"
        else
            source "$target" init
        fi
    fi
    if [ "$filename" = "upload.sh" ] || [ "$filename" = "restore.sh" ]; then
        local run_script
        prompt run_script "是否立即启动 $filename？[y/N]: "
        case "$run_script" in
            y|Y|yes|YES)
                if [ -r "$TTY" ]; then
                    "$target" < "$TTY"
                else
                    "$target"
                fi
                ;;
        esac
    fi
    echo "✅ $filename 安装完成"
    echo ""
}

# ─── 主流程 ──────────────────────────────────────
main() {
    local choice

    fetch_scripts

    while true; do
        print_menu
        prompt choice "请选择: "

        case "$choice" in
            0)
                exit 0
                ;;
            a)
                for script in "${SCRIPTS[@]}"; do
                    install_script "$script"
                done
                break
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && \
                   [ "$choice" -ge 1 ] && \
                   [ "$choice" -le "${#SCRIPTS[@]}" ]; then
                    install_script "${SCRIPTS[$((choice-1))]}"
                    break
                else
                    echo "❌ 无效选项"
                fi
                ;;
        esac
    done
}

main
