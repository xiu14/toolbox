#!/bin/bash

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s\n' "${BASH_SOURCE[0]}")"
CONFIG_FILE="$HOME/.proxy_config"
PID_FILE="$HOME/.ssh_proxy.pid"

# ─── 读取 / 保存配置 ──────────────────────────────
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        REMOTE_USER="root"
        REMOTE_HOST=""
        REMOTE_PORT="22"
        LOCAL_PORT="1080"
        ALIAS_ON="pon"
        ALIAS_OFF="poff"
        ALIAS_ST="pst"
    fi
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
REMOTE_USER="$REMOTE_USER"
REMOTE_HOST="$REMOTE_HOST"
REMOTE_PORT="$REMOTE_PORT"
LOCAL_PORT="$LOCAL_PORT"
ALIAS_ON="$ALIAS_ON"
ALIAS_OFF="$ALIAS_OFF"
ALIAS_ST="$ALIAS_ST"
EOF
}

# ─── 代理核心 ────────────────────────────────────
start() {
    load_config
    if [ -z "$REMOTE_HOST" ]; then
        echo "❌ 未配置远程主机，请先运行 pxy → 修改配置"
        return 1
    fi

    pkill -f "ssh -D $LOCAL_PORT" 2>/dev/null
    rm -f "$PID_FILE"
    sleep 1

    ssh -D $LOCAL_PORT -N -f \
        -p $REMOTE_PORT \
        -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -o ExitOnForwardFailure=yes \
        $REMOTE_USER@$REMOTE_HOST

    if [ $? -ne 0 ]; then
        echo "❌ SSH 连接失败，请检查 IP / 端口 / 密钥"
        return 1
    fi

    pgrep -f "ssh -D $LOCAL_PORT" > "$PID_FILE"

    export http_proxy=socks5://127.0.0.1:$LOCAL_PORT
    export https_proxy=socks5://127.0.0.1:$LOCAL_PORT
    export ALL_PROXY=socks5://127.0.0.1:$LOCAL_PORT

    echo "✅ 代理已启动，端口 $LOCAL_PORT"
}

stop() {
    load_config
    if [ -f "$PID_FILE" ]; then
        kill $(cat "$PID_FILE") 2>/dev/null
        rm -f "$PID_FILE"
    fi
    pkill -f "ssh -D $LOCAL_PORT" 2>/dev/null
    unset http_proxy https_proxy ALL_PROXY
    echo "🔴 代理已关闭"
}

status() {
    load_config
    echo ""
    if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        echo "🟢 代理运行中 (PID: $(cat $PID_FILE))"
        echo "📡 测试连通性..."
        RESULT=$(curl -s --max-time 5 --proxy socks5h://127.0.0.1:$LOCAL_PORT https://ip.sb)
        if [ -n "$RESULT" ]; then
            echo "✅ 当前出口 IP：$RESULT"
        else
            echo "❌ 连通测试失败（隧道可能已断）"
        fi
    else
        echo "⚫ 代理未运行"
    fi
    echo ""
}

# ─── 修改配置 ────────────────────────────────────
configure() {
    load_config
    echo ""
    echo "当前配置："
    echo "  用户    : $REMOTE_USER"
    echo "  主机 IP : ${REMOTE_HOST:-（未设置）}"
    echo "  SSH 端口: $REMOTE_PORT"
    echo "  本地端口: $LOCAL_PORT"
    echo ""
    echo "直接回车保留原值"
    echo ""

    read -p "远程用户 [$REMOTE_USER]: " input
    REMOTE_USER="${input:-$REMOTE_USER}"

    read -p "远程主机 IP [$REMOTE_HOST]: " input
    REMOTE_HOST="${input:-$REMOTE_HOST}"

    read -p "SSH 端口 [$REMOTE_PORT]: " input
    REMOTE_PORT="${input:-$REMOTE_PORT}"

    read -p "本地 SOCKS5 端口 [$LOCAL_PORT]: " input
    LOCAL_PORT="${input:-$LOCAL_PORT}"

    save_config
    echo ""
    echo "✅ 配置已保存"
}

setup_ssh_key() {
    load_config
    echo ""
    echo "🔑 配置 SSH 密钥免密登录"

    if [ -z "$REMOTE_HOST" ]; then
        echo "❌ 未配置远程主机，请先修改配置"
        return 1
    fi

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    # 没有密钥就生成
    if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
        echo "📝 生成 SSH 密钥..."
        ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -C "$(hostname)"
        echo "✅ 密钥已生成"
    else
        echo "✅ 已有 SSH 密钥，跳过生成"
    fi

    echo "📤 上传公钥到 $REMOTE_HOST（需要输入一次密码）..."
    if command -v ssh-copy-id >/dev/null 2>&1; then
        ssh-copy-id -i "$HOME/.ssh/id_ed25519.pub" \
            -p "$REMOTE_PORT" \
            "$REMOTE_USER@$REMOTE_HOST"
    else
        cat "$HOME/.ssh/id_ed25519.pub" | ssh \
            -p "$REMOTE_PORT" \
            -o StrictHostKeyChecking=no \
            "$REMOTE_USER@$REMOTE_HOST" \
            'mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && cat >> ~/.ssh/authorized_keys'
    fi

    if [ $? -eq 0 ]; then
        echo "✅ 密钥上传成功，之后无需密码"
    else
        echo "❌ 上传失败，可手动执行："
        echo "   ssh-copy-id -i ~/.ssh/id_ed25519.pub -p $REMOTE_PORT $REMOTE_USER@$REMOTE_HOST"
    fi
}


# ─── 设置别名 ────────────────────────────────────
setup_aliases() {
    load_config
    echo ""
    echo "当前别名："
    echo "  启动: $ALIAS_ON"
    echo "  关闭: $ALIAS_OFF"
    echo "  状态: $ALIAS_ST"
    echo ""
    echo "直接回车保留原值"
    echo ""

    read -p "启动别名 [$ALIAS_ON]: " input
    ALIAS_ON="${input:-$ALIAS_ON}"

    read -p "关闭别名 [$ALIAS_OFF]: " input
    ALIAS_OFF="${input:-$ALIAS_OFF}"

    read -p "状态别名 [$ALIAS_ST]: " input
    ALIAS_ST="${input:-$ALIAS_ST}"

    save_config
    _write_aliases
}

_write_aliases() {
    local BASHRC="$HOME/.bashrc"
    touch "$BASHRC"
    # 清除旧别名
    sed -i '/# PROXY_ALIAS/d' "$BASHRC"
    # 写入新别名
    echo "alias $ALIAS_ON=\"source $SCRIPT_PATH start\" # PROXY_ALIAS" >> "$BASHRC"
    echo "alias $ALIAS_OFF=\"source $SCRIPT_PATH stop\" # PROXY_ALIAS" >> "$BASHRC"
    echo "alias $ALIAS_ST=\"source $SCRIPT_PATH status\" # PROXY_ALIAS" >> "$BASHRC"
    echo "alias pxy=\"source $SCRIPT_PATH menu\" # PROXY_ALIAS" >> "$BASHRC"

    alias "$ALIAS_ON=source $SCRIPT_PATH start"
    alias "$ALIAS_OFF=source $SCRIPT_PATH stop"
    alias "$ALIAS_ST=source $SCRIPT_PATH status"
    alias "pxy=source $SCRIPT_PATH menu"

    echo ""
    echo "✅ 别名已写入并生效："
    echo "   $ALIAS_ON / $ALIAS_OFF / $ALIAS_ST / pxy"
    echo ""
    echo "如当前终端还识别不了 pxy，请执行："
    echo "   source ~/.bashrc"
}

# ─── 主菜单 ──────────────────────────────────────
menu() {
    load_config
    while true; do
        echo ""
        echo "╔═══════════════════════════════╗"
        echo "║       SSH 代理管理器          ║"
        echo "╠═══════════════════════════════╣"
        echo "║  1. 启动代理                  ║"
        echo "║  2. 关闭代理                  ║"
        echo "║  3. 查看状态 / 测试连通       ║"
        echo "║  4. 修改配置 (IP / 端口)      ║"
        echo "║  5. 修改别名                  ║"
        echo "║  6. 上传 SSH 密钥             ║"
        echo "║  0. 退出                      ║"
        echo "╚═══════════════════════════════╝"
        echo ""
        read -p "请选择: " choice
        case "$choice" in
            1) start ;;
            2) stop ;;
            3) status ;;
            4) configure ;;
            5) setup_aliases ;;
            6) setup_ssh_key ;;
            0) break ;;
            *) echo "无效选项" ;;
        esac
    done
}

# ─── 首次初始化 ──────────────────────────────────
init() {
    chmod +x "$SCRIPT_PATH"
    echo ""
    echo "🔧 初始化 SSH 代理脚本"
    echo "═══════════════════════"
    configure
    echo ""
    setup_ssh_key
    setup_aliases
    echo ""
    echo "🎉 完成！常用命令："
    load_config
    echo "   $ALIAS_ON   → 启动代理"
    echo "   $ALIAS_OFF  → 关闭代理"
    echo "   $ALIAS_ST   → 状态 / 测试"
    echo "   pxy  → 打开菜单"
}

# ─── 入口 ────────────────────────────────────────
case "$1" in
    start)  load_config; start  ;;
    stop)   load_config; stop   ;;
    status) load_config; status ;;
    menu)   menu ;;
    init)   init ;;
    *)
        if [ ! -f "$CONFIG_FILE" ]; then
            init
        else
            menu
        fi
        ;;
esac
