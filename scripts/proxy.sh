#!/bin/bash

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s\n' "${BASH_SOURCE[0]}")"
CONFIG_FILE="$HOME/.proxy_config"
PID_FILE="$HOME/.ssh_proxy.pid"
MONITOR_PID_FILE="$HOME/.ssh_proxy_monitor.pid"
REDSOCKS_PID_FILE="$HOME/.ssh_proxy_redsocks.pid"
REDSOCKS_CONF_FILE="$HOME/.ssh_proxy_redsocks.conf"
IPTABLES_CHAIN="SSH_PROXY"

set_defaults() {
    REMOTE_USER="${REMOTE_USER:-root}"
    REMOTE_HOST="${REMOTE_HOST:-}"
    REMOTE_PORT="${REMOTE_PORT:-22}"
    LOCAL_PORT="${LOCAL_PORT:-1080}"
    REDSOCKS_PORT="${REDSOCKS_PORT:-12345}"
    ALIAS_ON="${ALIAS_ON:-pon}"
    ALIAS_OFF="${ALIAS_OFF:-poff}"
    ALIAS_ST="${ALIAS_ST:-pst}"
}

# ─── 读取 / 保存配置 ──────────────────────────────
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    set_defaults
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
REMOTE_USER="$REMOTE_USER"
REMOTE_HOST="$REMOTE_HOST"
REMOTE_PORT="$REMOTE_PORT"
LOCAL_PORT="$LOCAL_PORT"
REDSOCKS_PORT="$REDSOCKS_PORT"
ALIAS_ON="$ALIAS_ON"
ALIAS_OFF="$ALIAS_OFF"
ALIAS_ST="$ALIAS_ST"
EOF
}

# ─── 代理核心 ────────────────────────────────────
notify_disconnected() {
    local message="⚠️ SSH 代理已断开，请运行 $ALIAS_ON 或 pxy 重新连接"

    if [ -w /dev/tty ]; then
        printf '\n%s\n' "$message" > /dev/tty
    else
        printf '\n%s\n' "$message"
    fi

    if command -v termux-notification >/dev/null 2>&1; then
        termux-notification --title "SSH 代理已断开" --content "请运行 $ALIAS_ON 或 pxy 重新连接" >/dev/null 2>&1
    elif command -v termux-toast >/dev/null 2>&1; then
        termux-toast "SSH 代理已断开" >/dev/null 2>&1
    fi
}

start_monitor() {
    local ssh_pid="$1"
    local monitor_pid

    if [ -f "$MONITOR_PID_FILE" ]; then
        kill "$(cat "$MONITOR_PID_FILE")" 2>/dev/null
        rm -f "$MONITOR_PID_FILE"
    fi

    (
        while true; do
            sleep 5

            if [ ! -f "$PID_FILE" ]; then
                exit 0
            fi

            if [ "$(cat "$PID_FILE" 2>/dev/null)" != "$ssh_pid" ]; then
                exit 0
            fi

            if ! kill -0 "$ssh_pid" 2>/dev/null; then
                load_config
                rm -f "$PID_FILE" "$MONITOR_PID_FILE"
                notify_disconnected
                exit 0
            fi
        done
    ) &

    monitor_pid="$!"
    disown "$monitor_pid" 2>/dev/null
    echo "$monitor_pid" > "$MONITOR_PID_FILE"
}

start() {
    load_config
    local ssh_pid

    if [ -z "$REMOTE_HOST" ]; then
        echo "❌ 未配置远程主机，请先运行 pxy → 修改配置"
        return 1
    fi

    pkill -f "ssh -D $LOCAL_PORT" 2>/dev/null
    if [ -f "$MONITOR_PID_FILE" ]; then
        kill "$(cat "$MONITOR_PID_FILE")" 2>/dev/null
    fi
    rm -f "$PID_FILE" "$MONITOR_PID_FILE"
    sleep 1

    ssh -D "$LOCAL_PORT" -N -f \
        -p "$REMOTE_PORT" \
        -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -o ExitOnForwardFailure=yes \
        "$REMOTE_USER@$REMOTE_HOST"

    if [ $? -ne 0 ]; then
        echo "❌ SSH 连接失败，请检查 IP / 端口 / 密钥"
        return 1
    fi

    ssh_pid="$(pgrep -f "ssh -D $LOCAL_PORT" | tail -n 1)"
    if [ -z "$ssh_pid" ]; then
        echo "❌ SSH 已返回成功，但未找到代理进程"
        return 1
    fi

    echo "$ssh_pid" > "$PID_FILE"
    start_monitor "$ssh_pid"

    export http_proxy=socks5h://127.0.0.1:$LOCAL_PORT
    export https_proxy=socks5h://127.0.0.1:$LOCAL_PORT
    export all_proxy=socks5h://127.0.0.1:$LOCAL_PORT
    export HTTP_PROXY=socks5h://127.0.0.1:$LOCAL_PORT
    export HTTPS_PROXY=socks5h://127.0.0.1:$LOCAL_PORT
    export ALL_PROXY=socks5h://127.0.0.1:$LOCAL_PORT

    echo "✅ 代理已启动，端口 $LOCAL_PORT，断开时会提示"
}

stop() {
    load_config
    if ! is_termux; then
        global_stop
    fi
    if [ -f "$MONITOR_PID_FILE" ]; then
        kill "$(cat "$MONITOR_PID_FILE")" 2>/dev/null
        rm -f "$MONITOR_PID_FILE"
    fi
    if [ -f "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null
        rm -f "$PID_FILE"
    fi
    pkill -f "ssh -D $LOCAL_PORT" 2>/dev/null
    unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
    echo "🔴 代理已关闭"
}

is_termux() {
    case "$PREFIX" in
        *com.termux*) return 0 ;;
    esac
    [ -d /data/data/com.termux/files/usr ]
}

run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "❌ 全局模式需要 root 权限或 sudo"
        return 1
    fi
}

global_requirements_ok() {
    if is_termux; then
        echo "❌ 当前是 Termux/Android 环境，已跳过 Linux 全局模式"
        echo "   Android 建议使用 VPN/TUN 模式代理工具；这个脚本只在默认 Linux 环境启用透明代理。"
        return 1
    fi

    if ! command -v iptables >/dev/null 2>&1; then
        echo "❌ 缺少 iptables"
        return 1
    fi

    return 0
}

install_redsocks_if_missing() {
    if command -v redsocks >/dev/null 2>&1; then
        return 0
    fi

    if ! command -v apt >/dev/null 2>&1; then
        echo "❌ 缺少 redsocks，且当前系统没有 apt，无法自动安装"
        echo "   请手动安装 redsocks 后再启动全局模式"
        return 1
    fi

    echo "📦 未检测到 redsocks，先启动普通 SSH 代理以便 apt 联网..."
    start || return 1

    echo "📦 正在安装 redsocks ..."
    if [ "$(id -u)" -eq 0 ]; then
        apt install redsocks -y
    elif command -v sudo >/dev/null 2>&1; then
        sudo env \
            http_proxy="$http_proxy" \
            https_proxy="$https_proxy" \
            all_proxy="$all_proxy" \
            HTTP_PROXY="$HTTP_PROXY" \
            HTTPS_PROXY="$HTTPS_PROXY" \
            ALL_PROXY="$ALL_PROXY" \
            apt install redsocks -y
    else
        echo "❌ 安装 redsocks 需要 root 权限或 sudo"
        return 1
    fi

    if [ $? -ne 0 ]; then
        echo "❌ redsocks 安装失败"
        return 1
    fi

    if ! command -v redsocks >/dev/null 2>&1; then
        echo "❌ redsocks 安装完成后仍不可用，请检查 PATH"
        return 1
    fi

    echo "✅ redsocks 安装完成"
    return 0
}

write_redsocks_config() {
    cat > "$REDSOCKS_CONF_FILE" << EOF
base {
    log_debug = off;
    log_info = off;
    log = "stderr";
    daemon = on;
    redirector = iptables;
}

redsocks {
    local_ip = 0.0.0.0;
    local_port = $REDSOCKS_PORT;
    ip = 127.0.0.1;
    port = $LOCAL_PORT;
    type = socks5;
}
EOF
}

start_redsocks() {
    cleanup_redsocks_runtime
    write_redsocks_config
    redsocks -c "$REDSOCKS_CONF_FILE" -p "$REDSOCKS_PID_FILE"
}

kill_redsocks_port() {
    local pids

    if command -v fuser >/dev/null 2>&1; then
        if [ "$(id -u)" -eq 0 ]; then
            fuser -k "${REDSOCKS_PORT}/tcp" >/dev/null 2>&1 || true
        elif command -v sudo >/dev/null 2>&1; then
            sudo fuser -k "${REDSOCKS_PORT}/tcp" >/dev/null 2>&1 || true
        else
            fuser -k "${REDSOCKS_PORT}/tcp" >/dev/null 2>&1 || true
        fi
        return 0
    fi

    if command -v lsof >/dev/null 2>&1; then
        pids="$(lsof -tiTCP:"$REDSOCKS_PORT" -sTCP:LISTEN 2>/dev/null)"
        if [ -n "$pids" ]; then
            if [ "$(id -u)" -eq 0 ]; then
                kill $pids 2>/dev/null || true
            elif command -v sudo >/dev/null 2>&1; then
                sudo kill $pids 2>/dev/null || true
            else
                kill $pids 2>/dev/null || true
            fi
        fi
    fi
}

cleanup_redsocks_runtime() {
    if [ -f "$REDSOCKS_PID_FILE" ]; then
        kill "$(cat "$REDSOCKS_PID_FILE")" 2>/dev/null
        rm -f "$REDSOCKS_PID_FILE"
    fi

    pkill -f redsocks 2>/dev/null
    kill_redsocks_port
    sleep 1
}

iptables_insert_once() {
    if ! run_root iptables -t nat -C "$@" >/dev/null 2>&1; then
        run_root iptables -t nat -I "$@"
    fi
}

setup_iptables_global() {
    run_root iptables -t nat -N "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
    run_root iptables -t nat -F "$IPTABLES_CHAIN"

    run_root iptables -t nat -A "$IPTABLES_CHAIN" -d 0.0.0.0/8 -j RETURN
    run_root iptables -t nat -A "$IPTABLES_CHAIN" -d 10.0.0.0/8 -j RETURN
    run_root iptables -t nat -A "$IPTABLES_CHAIN" -d 100.64.0.0/10 -j RETURN
    run_root iptables -t nat -A "$IPTABLES_CHAIN" -d 127.0.0.0/8 -j RETURN
    run_root iptables -t nat -A "$IPTABLES_CHAIN" -d 169.254.0.0/16 -j RETURN
    run_root iptables -t nat -A "$IPTABLES_CHAIN" -d 172.16.0.0/12 -j RETURN
    run_root iptables -t nat -A "$IPTABLES_CHAIN" -d 192.168.0.0/16 -j RETURN
    run_root iptables -t nat -A "$IPTABLES_CHAIN" -d 224.0.0.0/4 -j RETURN
    run_root iptables -t nat -A "$IPTABLES_CHAIN" -d 240.0.0.0/4 -j RETURN

    if [ -n "$REMOTE_HOST" ]; then
        run_root iptables -t nat -A "$IPTABLES_CHAIN" -p tcp -d "$REMOTE_HOST" --dport "$REMOTE_PORT" -j RETURN 2>/dev/null || true
    fi

    run_root iptables -t nat -A "$IPTABLES_CHAIN" -p tcp -j REDIRECT --to-ports "$REDSOCKS_PORT"
    iptables_insert_once OUTPUT -p tcp -j "$IPTABLES_CHAIN"
    iptables_insert_once PREROUTING -i docker0 -p tcp -j "$IPTABLES_CHAIN"
    iptables_insert_once PREROUTING -i br+ -p tcp -j "$IPTABLES_CHAIN"
}

clear_iptables_global() {
    if ! command -v iptables >/dev/null 2>&1; then
        return 0
    fi

    while run_root iptables -t nat -C OUTPUT -p tcp -j "$IPTABLES_CHAIN" >/dev/null 2>&1; do
        run_root iptables -t nat -D OUTPUT -p tcp -j "$IPTABLES_CHAIN" || break
    done

    while run_root iptables -t nat -C PREROUTING -p tcp -j "$IPTABLES_CHAIN" >/dev/null 2>&1; do
        run_root iptables -t nat -D PREROUTING -p tcp -j "$IPTABLES_CHAIN" || break
    done

    while run_root iptables -t nat -C PREROUTING -i docker0 -p tcp -j "$IPTABLES_CHAIN" >/dev/null 2>&1; do
        run_root iptables -t nat -D PREROUTING -i docker0 -p tcp -j "$IPTABLES_CHAIN" || break
    done

    while run_root iptables -t nat -C PREROUTING -i br+ -p tcp -j "$IPTABLES_CHAIN" >/dev/null 2>&1; do
        run_root iptables -t nat -D PREROUTING -i br+ -p tcp -j "$IPTABLES_CHAIN" || break
    done

    run_root iptables -t nat -F "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
    run_root iptables -t nat -X "$IPTABLES_CHAIN" >/dev/null 2>&1 || true
}

global_start() {
    load_config
    local proxy_started=0

    if ! global_requirements_ok; then
        return 1
    fi

    if ! command -v redsocks >/dev/null 2>&1; then
        install_redsocks_if_missing || return 1
        proxy_started=1
    fi

    if [ "$proxy_started" -eq 0 ]; then
        start || return 1
    fi

    start_redsocks || {
        echo "❌ redsocks 启动失败"
        return 1
    }

    clear_iptables_global
    setup_iptables_global || {
        echo "❌ iptables 规则设置失败，正在回滚"
        clear_iptables_global
        return 1
    }

    echo "🌐 Linux 全局模式已启动"
    echo "   TCP 流量会经 redsocks:$REDSOCKS_PORT 转发到 SOCKS5:$LOCAL_PORT"
    echo "   Docker bridge 容器的 TCP 流量也会尝试走代理；UDP/DNS 不属于此模式覆盖范围。"
}

global_stop() {
    load_config
    clear_iptables_global
    cleanup_redsocks_runtime
    rm -f "$REDSOCKS_CONF_FILE"

    echo "🌐 Linux 全局模式已关闭"
}

global_status() {
    load_config
    echo ""
    if is_termux; then
        echo "⚫ Linux 全局模式：当前环境为 Termux，未启用"
        echo ""
        return 0
    fi

    if [ -f "$REDSOCKS_PID_FILE" ] && kill -0 "$(cat "$REDSOCKS_PID_FILE")" 2>/dev/null; then
        echo "🟢 redsocks 运行中 (PID: $(cat "$REDSOCKS_PID_FILE"))"
    else
        echo "⚫ redsocks 未运行"
    fi

    if command -v iptables >/dev/null 2>&1 && run_root iptables -t nat -S "$IPTABLES_CHAIN" >/dev/null 2>&1; then
        echo "🟢 iptables 透明代理链存在：$IPTABLES_CHAIN"
    else
        echo "⚫ iptables 透明代理链不存在"
    fi
    echo ""
}

status() {
    load_config
    echo ""
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
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
    echo "  全局转发端口: $REDSOCKS_PORT"
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

    read -p "Linux 全局模式转发端口 [$REDSOCKS_PORT]: " input
    REDSOCKS_PORT="${input:-$REDSOCKS_PORT}"

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
        echo "║  7. Linux 全局模式开启        ║"
        echo "║  8. Linux 全局模式关闭        ║"
        echo "║  9. Linux 全局模式状态        ║"
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
            7) global_start ;;
            8) global_stop ;;
            9) global_status ;;
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
    global-on|global-start) load_config; global_start ;;
    global-off|global-stop) load_config; global_stop ;;
    global-status) load_config; global_status ;;
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
