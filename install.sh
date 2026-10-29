#!/bin/sh
# ============================================================================
#  hy2-node 一键脚本 —— 在 Alpine (NAT) VPS 上部署 Hysteria2 服务端
#
#  用法:
#    交互安装:  sh install.sh            (或下载后直接运行)
#    管道安装:  wget -qO- <raw_url>/install.sh | sh
#    批量安装:  HY2_PORT=20000 sh install.sh   (其余走默认值,环境变量见 README)
#
#  环境变量(全部可选,详见 README):
#    HY2_IP / HY2_PORT / HY2_LISTEN / HY2_PASSWORD
#    HY2_OBFUS=on / HY2_OBFUS_PASSWORD / HY2_DNAT=off
#    HY2_BIN=/path/to/hysteria(离线安装) / GH_PROXY=https://xx/(下载加速)
#
#  要求: Alpine 3.17+ / x86_64|arm64 / root
#  上游: https://github.com/apernet/hysteria
#  许可: MIT
# ============================================================================

set -u

# ---------------------------- 路径与常量 ------------------------------------
BIN_PATH="/usr/local/bin/hysteria"
CONF_DIR="/etc/hysteria"
CONF_FILE="${CONF_DIR}/config.yaml"
CERT_FILE="${CONF_DIR}/server.crt"
KEY_FILE="${CONF_DIR}/server.key"
STATE_FILE="${CONF_DIR}/.env"
INIT_FILE="/etc/init.d/hysteria"
CONFD_FILE="/etc/conf.d/hysteria"
LOG_FILE="/var/log/hysteria.log"

SNI="bing.com"
MASQ_URL="https://news.ycombinator.com/"
UPSTREAM="apernet/hysteria"
# GitHub 直连失败后依次尝试的镜像前缀(2026-10 验证可用,可被 GH_PROXY 覆盖)
MIRRORS="https://gh-proxy.com/ https://ghfast.top/"
GOMEMLIMIT_DEF="64MiB"

# ---------------------------- 输出辅助 --------------------------------------
if [ -t 1 ]; then
    C_G='\033[1;32m'; C_R='\033[1;31m'; C_Y='\033[1;33m'; C_C='\033[1;36m'; C_0='\033[0m'
else
    C_G=''; C_R=''; C_Y=''; C_C=''; C_0=''
fi
info() { printf "${C_G}%s${C_0}\n" "$*"; }
warn() { printf "${C_Y}%s${C_0}\n" "$*"; }
err()  { printf "${C_R}%s${C_0}\n" "$*"; }
step() { printf "\n${C_C}==== %s ====${C_0}\n" "$*"; }
die()  { err "错误: $*"; exit 1; }

print_banner() {
    printf '%s\n' "--------------------------------------------"
    printf '%s\n' "  hy2-node · Hysteria2 一键部署脚本"
    printf '%s\n' "  适用: Alpine / NAT VPS / 低内存"
    printf '%s\n' "  上游: github.com/${UPSTREAM}"
    printf '%s\n' "--------------------------------------------"
}

# 交互读取: $1=提示 $2=默认值,结果放入 ANSWER(始终从 /dev/tty 读,兼容管道安装)
ask() {
    if [ -n "$2" ]; then
        printf '%s [%s]: ' "$1" "$2"
    else
        printf '%s: ' "$1"
    fi
    ANSWER=""
    if [ -c /dev/tty ]; then
        read -r ANSWER </dev/tty || ANSWER=""
    fi
    [ -n "$ANSWER" ] || ANSWER="$2"
}

pause() {
    printf '\n按回车返回菜单...'
    if [ -c /dev/tty ]; then read -r _x </dev/tty || :; fi
    printf '\n'
}

is_yes() { case "$1" in y|Y|yes|YES|Yes|1|true) return 0 ;; *) return 1 ;; esac; }

rand_pw() {
    openssl rand -hex 12 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c 24
}

# ---------------------------- 基础检测 --------------------------------------
valid_port() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# 解析 "20000" 或 "20000-20050" -> P_A / P_B
parse_ports() {
    P_A=""; P_B=""
    case "$1" in
        *-*) P_A="${1%-*}"; P_B="${1#*-}" ;;
        *)   P_A="$1"; P_B="$1" ;;
    esac
    valid_port "$P_A" && valid_port "$P_B" || return 1
    [ "$P_A" -le "$P_B" ] || return 1
}

fetch_url() { # $1=url -> stdout
    if command -v curl >/dev/null 2>&1; then
        curl -4 -fs --connect-timeout 5 "$1" 2>/dev/null
    else
        wget -q -T 5 -O - "$1" 2>/dev/null
    fi
}

detect_ip() {
    _ip=""
    for _u in https://api.ipify.org https://ifconfig.me https://icanhazip.com https://ip.sb; do
        _ip="$(fetch_url "$_u" | tr -d '[:space:]')"
        [ -n "$_ip" ] && break
        _ip=""
    done
    [ -n "$_ip" ] || return 1
    case "$_ip" in
        *[!0-9.]*) return 1 ;;   # 不是纯 IPv4(可能是 v6),交由上层处理
    esac
    printf '%s' "$_ip"
}

detect_if() { # 默认路由网卡名
    ip route 2>/dev/null | sed -n 's/^default .*dev \([^ ][^ ]*\).*/\1/p' | head -n 1
}

# ---------------------------- 安装动作 --------------------------------------
ensure_deps() {
    # iptables 仅在启用端口跳跃时才装(见 apply_config),给小内存机器省空间
    _pkgs="curl openssl ca-certificates"
    apk add -q --no-cache $_pkgs >/dev/null 2>&1 || apk add -q $_pkgs >/dev/null 2>&1 \
        || die "依赖安装失败,请检查网络与 apk 源(apk update)"
}

ensure_iptables() {
    command -v iptables >/dev/null 2>&1 && return 0
    apk add -q --no-cache iptables >/dev/null 2>&1 \
        || warn "iptables 安装失败,端口跳跃将不可用(自动降级单端口)"
}

download_binary() { # $1=目标路径;成功返回0
    _base="https://github.com/${UPSTREAM}/releases/latest/download/hysteria-linux-${ARCH}"
    for _p in ${GH_PROXY:-} "" $MIRRORS; do   # 用户显式设置的代理优先,其次直连,最后镜像
        _url="${_p}${_base}"
        printf '  尝试: %s\n' "$_url"
        if curl -fSL --connect-timeout 10 --retry 2 -o "$1" "$_url" 2>/dev/null; then
            chmod +x "$1"
            if "$1" version >/dev/null 2>&1; then
                info "下载成功"
                return 0
            fi
            warn "下载的文件无法运行,换下一个源"
        fi
    done
    return 1
}

place_binary() {
    mkdir -p /usr/local/bin
    if [ -n "${HY2_BIN:-}" ] && [ -f "${HY2_BIN}" ]; then
        cp -f "${HY2_BIN}" "$BIN_PATH" || die "复制本地二进制失败: ${HY2_BIN}"
        chmod +x "$BIN_PATH"
        "$BIN_PATH" version >/dev/null 2>&1 || die "HY2_BIN 指定的文件无法运行(架构不符?)"
        info "已使用本地二进制: ${HY2_BIN}"
        return 0
    fi
    _tmp="$(mktemp /tmp/hy2bin.XXXXXX)" || die "mktemp 失败"
    if ! download_binary "$_tmp"; then
        rm -f "$_tmp"
        err "所有下载源均失败。可:"
        err "  1) 设置加速前缀重试: GH_PROXY=https://gh-proxy.com/ sh install.sh"
        err "  2) 本地下载后离线安装: HY2_BIN=/path/to/hysteria-linux-${ARCH} sh install.sh"
        die "下载终止"
    fi
    mv -f "$_tmp" "$BIN_PATH"
}

gen_cert() {
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        info "复用已有自签证书"
        return 0
    fi
    openssl ecparam -genkey -name prime256v1 -out "$KEY_FILE" 2>/dev/null \
        || die "生成私钥失败"
    openssl req -new -x509 -days 3650 -key "$KEY_FILE" -out "$CERT_FILE" \
        -subj "/CN=${SNI}" -addext "subjectAltName=DNS:${SNI}" 2>/dev/null || die "生成证书失败"
    chmod 600 "$KEY_FILE" "$CERT_FILE"
    info "已生成自签证书(CN=${SNI},含 SAN,有效期 10 年)"
}

write_config() {
    {
        printf 'listen: :%s\n\n' "$LISTEN_PORT"
        printf 'tls:\n'
        printf '  cert: %s\n' "$CERT_FILE"
        printf '  key: %s\n\n' "$KEY_FILE"
        printf 'auth:\n'
        printf '  type: password\n'
        printf '  password: "%s"\n' "$PASSWORD"
        if [ "$OBFUS" = "on" ]; then
            printf '\nobfs:\n'
            printf '  type: salamander\n'
            printf '  salamander:\n'
            printf '    password: "%s"\n' "$OBFUS_PASSWORD"
        fi
        printf '\nmasquerade:\n'
        printf '  type: proxy\n'
        printf '  proxy:\n'
        printf '    url: %s\n' "$MASQ_URL"
        printf '    rewriteHost: true\n'
    } > "$CONF_FILE"
    chmod 600 "$CONF_FILE"
    info "已写入 ${CONF_FILE}"
}

write_init() {
    cat > "$INIT_FILE" <<'ICEOF'
#!/sbin/openrc-run

description="Hysteria 2 server (hy2 node)"

command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
supervisor=supervise-daemon
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"

: "${GOMEMLIMIT:=64MiB}"
export GOMEMLIMIT

depend() {
    after net firewall
}

dnat_rule_args() {
    echo "-t nat PREROUTING ${HY2_DNAT_IF:+-i $HY2_DNAT_IF} -p udp --dport $HY2_DNAT_PORTS -j REDIRECT --to-ports $HY2_DNAT_TARGET"
}

dnat_add() {
    [ -n "${HY2_DNAT_PORTS:-}" ] || return 0
    if iptables $(dnat_rule_args) -C >/dev/null 2>&1; then
        einfo "端口跳跃规则已存在,跳过"
        return 0
    fi
    if ! iptables $(dnat_rule_args) -A >/dev/null 2>&1; then
        eerror "无法添加 iptables 端口跳跃规则(容器可能缺少 NET_ADMIN)"
        return 1
    fi
    einfo "端口跳跃: udp ${HY2_DNAT_PORTS} -> ${HY2_DNAT_TARGET}"
}

dnat_del() {
    [ -n "${HY2_DNAT_PORTS:-}" ] || return 0
    iptables $(dnat_rule_args) -D >/dev/null 2>&1
    return 0
}

start_pre() {
    if [ ! -f /etc/hysteria/config.yaml ]; then
        eerror "缺少配置文件 /etc/hysteria/config.yaml"
        return 1
    fi
    dnat_add || ewarn "端口跳跃不可用,仅单端口监听"
}

stop_post() {
    dnat_del
}
ICEOF
    chmod +x "$INIT_FILE"
    info "已写入 OpenRC 服务 ${INIT_FILE}"
}

write_confd() {
    _ports=""
    if [ "$DNAT" -eq 1 ]; then
        _a="${PORT_RANGE%%-*}"; _b="${PORT_RANGE##*-}"
        _ports="${_a}:${_b}"
    fi
    cat > "$CONFD_FILE" <<EOF
# 由 hy2-node 一键脚本生成
# 端口跳跃: HY2_DNAT_PORTS 为 iptables 范围语法(冒号),留空则不启用
HY2_DNAT_PORTS="${_ports}"
HY2_DNAT_TARGET="${LISTEN_PORT}"
HY2_DNAT_IF="${DNAT_IF}"
# Go 运行时内存软限制
GOMEMLIMIT="${GOMEMLIMIT_DEF}"
EOF
    info "已写入 ${CONFD_FILE}"
}

save_state() {
    # shellcheck disable=SC2034
    cat > "$STATE_FILE" <<EOF
# hy2 节点状态(供管理菜单读取,勿删)
PUBLIC_IP="${PUBLIC_IP}"
PUBLIC_PORT="${PUBLIC_PORT}"
PORT_RANGE="${PORT_RANGE}"
LISTEN_PORT="${LISTEN_PORT}"
PASSWORD="${PASSWORD}"
SNI="${SNI}"
OBFUS="${OBFUS}"
OBFUS_PASSWORD="${OBFUS_PASSWORD}"
EOF
    chmod 600 "$STATE_FILE"
}

prepare_dnat() { # 检测网卡与 iptables 能力,不可用则自动降级为单端口
    DNAT_IF=""
    [ "$DNAT" -eq 1 ] || return 0
    ensure_iptables
    DNAT_IF="$(detect_if)"
    _a="${PORT_RANGE%%-*}"; _b="${PORT_RANGE##*-}"
    if [ -n "$DNAT_IF" ]; then
        _args="-t nat PREROUTING -i ${DNAT_IF} -p udp --dport ${_a}:${_b} -j REDIRECT --to-ports ${LISTEN_PORT}"
    else
        _args="-t nat PREROUTING -p udp --dport ${_a}:${_b} -j REDIRECT --to-ports ${LISTEN_PORT}"
    fi
    if iptables $_args -C >/dev/null 2>&1; then return 0; fi
    if iptables $_args -A >/dev/null 2>&1; then
        iptables $_args -D >/dev/null 2>&1
        return 0
    fi
    warn "当前环境无法添加 iptables NAT 规则(受限 LXC?),已跳过端口跳跃"
    warn "节点仍可用,客户端直接连主端口 ${LISTEN_PORT} 即可"
    DNAT=0
}

restart_and_verify() {
    rc-update add hysteria default >/dev/null 2>&1
    # 前面已确保服务处于停止状态,这里用 start 而非 restart
    rc-service hysteria start >/dev/null 2>&1
    sleep 2
    if ! rc-service hysteria status >/dev/null 2>&1; then
        err "hysteria 启动失败,最近日志:"
        tail -n 15 "$LOG_FILE" 2>/dev/null
        die "请根据日志排查(常见原因: 配置错误 / 端口被占用)"
    fi
    info "hysteria 服务已启动(supervise-daemon 守护,开机自启)"
    if netstat -uln 2>/dev/null | grep -q ":${LISTEN_PORT} "; then
        info "已监听 UDP ${LISTEN_PORT}"
    else
        warn "暂未探测到 UDP ${LISTEN_PORT} 监听,可稍后执行 netstat -uln 确认"
    fi
}

# ---------------------------- 配置向导 --------------------------------------
load_state_defaults() {
    D_IP=""; D_PORT=""; D_LISTEN=""; D_PASS=""; D_OBFUS="off"; D_OBFUS_PW=""
    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE"
        D_IP="${PUBLIC_IP:-}"
        D_LISTEN="${LISTEN_PORT:-}"
        D_PASS="${PASSWORD:-}"
        D_OBFUS="${OBFUS:-off}"
        D_OBFUS_PW="${OBFUS_PASSWORD:-}"
        if [ -n "${PORT_RANGE:-}" ]; then D_PORT="${PORT_RANGE}"; else D_PORT="${PUBLIC_PORT:-}"; fi
    fi
}

wizard_interactive() {
    INTERACTIVE=1
    load_state_defaults

    if [ -z "$D_IP" ]; then
        _det="$(detect_ip)" || _det=""
        if [ -n "$_det" ]; then
            D_IP="$_det"
            info "探测到公网 IP: ${D_IP}(NAT 机即出口共享 IP)"
        else
            warn "未能自动探测公网 IP,请手动输入"
        fi
    fi
    PUBLIC_IP=""
    while [ -z "$PUBLIC_IP" ]; do
        ask "公网 IP 或域名(客户端连接地址)" "$D_IP"
        PUBLIC_IP="$ANSWER"
        [ -n "$PUBLIC_IP" ] || err "不能为空"
    done

    PORT_RANGE=""
    while :; do
        ask "公网端口(单个如 20000,范围如 20000-20050)" "$D_PORT"
        if parse_ports "$ANSWER"; then
            PUBLIC_PORT="$P_A"
            if [ "$P_A" -eq "$P_B" ]; then PORT_RANGE=""; else PORT_RANGE="${P_A}-${P_B}"; fi
            break
        fi
        err "端口格式不正确(示例: 20000 或 20000-20050,起始<=结束)"
    done

    _dlisten="${D_LISTEN:-$P_A}"
    while :; do
        ask "内部监听端口(NAT 映射通常 1:1,回车=与主端口一致)" "$_dlisten"
        if valid_port "$ANSWER"; then LISTEN_PORT="$ANSWER"; break; fi
        err "请输入 1-65535 之间的数字"
    done

    DNAT=0
    if [ -n "$PORT_RANGE" ]; then
        ask "启用 iptables 端口跳跃(整段 ${PORT_RANGE} 转发到 ${LISTEN_PORT}) [Y/n]" "Y"
        if is_yes "$ANSWER"; then DNAT=1; else DNAT=0; fi
    fi

    _d="N"; [ "$D_OBFUS" = "on" ] && _d="Y"
    ask "开启 obfs 混淆(抗 UDP QoS,客户端需同步配置) [y/N]" "$_d"
    if is_yes "$ANSWER"; then OBFUS="on"; else OBFUS="off"; fi

    if [ "$OBFUS" = "on" ]; then
        [ -z "$D_OBFUS_PW" ] && D_OBFUS_PW="$(rand_pw)"
        ask "obfs 密码(salamander)" "$D_OBFUS_PW"
        OBFUS_PASSWORD="$ANSWER"
    else
        OBFUS_PASSWORD=""
    fi

    [ -z "$D_PASS" ] && D_PASS="$(rand_pw)"
    ask "连接密码(回车=使用下方默认)" "$D_PASS"
    PASSWORD="$ANSWER"
    case "$PASSWORD" in
        *[!A-Za-z0-9]*) warn "密码含特殊字符,分享链接可能需手动转义,建议字母数字" ;;
    esac
}

wizard_batch() {
    INTERACTIVE=0
    parse_ports "${HY2_PORT:?HY2_PORT 未设置}" || die "HY2_PORT 格式错误(示例: 20000 或 20000-20050)"
    PUBLIC_PORT="$P_A"
    PORT_RANGE=""
    [ "$P_A" -ne "$P_B" ] && PORT_RANGE="${P_A}-${P_B}"
    LISTEN_PORT="${HY2_LISTEN:-$P_A}"
    valid_port "$LISTEN_PORT" || die "HY2_LISTEN 无效"
    PUBLIC_IP="${HY2_IP:-$(detect_ip)}" || die "无法探测公网 IP,请设置 HY2_IP"
    [ -n "$PUBLIC_IP" ] || die "无法探测公网 IP,请设置 HY2_IP"
    PASSWORD="${HY2_PASSWORD:-$(rand_pw)}"
    OBFUS="off"
    case "${HY2_OBFUS:-}" in on|1|true|yes) OBFUS="on" ;; esac
    OBFUS_PASSWORD="${HY2_OBFUS_PASSWORD:-}"
    if [ "$OBFUS" = "on" ] && [ -z "$OBFUS_PASSWORD" ]; then OBFUS_PASSWORD="$(rand_pw)"; fi
    DNAT=0
    if [ -n "$PORT_RANGE" ] && [ "${HY2_DNAT:-on}" != "off" ]; then DNAT=1; fi
}

wizard() {
    if [ -n "${HY2_PORT:-}" ]; then
        wizard_batch
    elif [ -c /dev/tty ]; then
        wizard_interactive
    else
        die "无交互终端且未设置 HY2_PORT。请下载脚本后运行 sh install.sh,或用环境变量批量模式(见 README)"
    fi
}

confirm_or_abort() {
    printf '\n'
    printf '  公网地址  : %s%s\n' "$PUBLIC_IP" "${PORT_RANGE:+:${PORT_RANGE}}"
    printf '  主端口    : %s\n' "$PUBLIC_PORT"
    [ -n "$PORT_RANGE" ] && printf '  端口跳跃  : %s\n' "$([ "$DNAT" -eq 1 ] && echo 开启 || echo 关闭)"
    printf '  监听端口  : %s\n' "$LISTEN_PORT"
    printf '  密码      : %s\n' "$PASSWORD"
    printf '  obfs 混淆 : %s%s\n' "$OBFUS" "${OBFUS_PASSWORD:+(${OBFUS_PASSWORD})}"
    printf '  证书      : 自签(CN=%s,客户端需 insecure=1)\n' "$SNI"
    printf '\n'
    ask "确认以上配置并安装? [Y/n]" "Y"
    if is_yes "$ANSWER"; then return 0; fi
    info "已取消,未做任何改动"
    return 1
}

apply_config() { # 向导 -> 确认 -> 停旧服务(清旧DNAT规则) -> 写文件 -> 启动 -> 展示
    ensure_deps
    wizard
    prepare_dnat
    if [ "$INTERACTIVE" -eq 1 ]; then
        confirm_or_abort || return 1
    fi
    # 必须先用"旧 conf.d"停服务(stop_post 会按旧参数删 iptables 规则),
    # 再写新文件,否则改了端口段后旧规则会残留在内核里
    if rc-service hysteria status >/dev/null 2>&1; then
        rc-service hysteria stop >/dev/null 2>&1
    fi
    mkdir -p "$CONF_DIR"
    place_binary
    gen_cert
    write_config
    write_init
    write_confd
    save_state
    restart_and_verify
    show_info
}

# ---------------------------- 信息展示 --------------------------------------
show_info() {
    [ -f "$STATE_FILE" ] || die "状态文件缺失,请重新安装"
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    _link="hy2://${PASSWORD}@${PUBLIC_IP}:${PUBLIC_PORT}/?insecure=1&sni=${SNI}"
    [ -n "${PORT_RANGE:-}" ] && _link="${_link}&mport=${PORT_RANGE}"
    [ "${OBFUS:-off}" = "on" ] && _link="${_link}&obfs=salamander&obfs-password=${OBFUS_PASSWORD}"

    printf '\n'
    printf '  ==================== 节点信息 ====================\n'
    printf '  服务器      : %s\n' "$PUBLIC_IP"
    printf '  端口        : %s%s\n' "$PUBLIC_PORT" "${PORT_RANGE:+ (跳跃 ${PORT_RANGE})}"
    printf '  监听端口    : %s / UDP\n' "$LISTEN_PORT"
    printf '  密码        : %s\n' "$PASSWORD"
    printf '  SNI         : %s (自签证书, insecure=1)\n' "$SNI"
    printf '  obfs        : %s%s\n' "${OBFUS:-off}" "${OBFUS_PASSWORD:+ (${OBFUS_PASSWORD})}"
    printf '  --------------------------------------------------\n'
    printf '  分享链接:\n'
    printf '\n'
    printf '  %s\n' "$_link"
    printf '\n'
    printf '  ====================================================\n'
    printf '  提示:\n'
    printf '  - 链接可直接导入 NekoBox / sing-box / v2rayN 等客户端\n'
    printf '  - mport(端口跳跃)仅部分客户端支持,不支持就去掉该参数\n'
    printf '  - 管理服务: rc-service hysteria start|stop|restart|status\n'
    printf '  - 查看日志: tail -f %s\n' "$LOG_FILE"
    printf '  ====================================================\n'
}

# ---------------------------- 管理菜单 --------------------------------------
hysteria_version() { "$BIN_PATH" version 2>/dev/null | sed -n '1p'; }

upgrade() {
    step "升级 hysteria"
    info "当前版本: $(hysteria_version)"
    _tmp="$(mktemp /tmp/hy2bin.XXXXXX)" || die "mktemp 失败"
    if ! download_binary "$_tmp"; then
        rm -f "$_tmp"
        err "下载失败,可稍后重试或设置 GH_PROXY 加速"
        return 1
    fi
    mv -f "$_tmp" "$BIN_PATH"
    rc-service hysteria restart >/dev/null 2>&1
    sleep 1
    info "已升级到: $(hysteria_version)"
    rc-service hysteria status >/dev/null 2>&1 || warn "服务未在运行,请检查日志"
}

uninstall() {
    ask "确认卸载?将删除程序/配置/证书/服务 [y/N]" "N"
    is_yes "$ANSWER" || { info "已取消"; return 1; }
    rc-service hysteria stop >/dev/null 2>&1
    rc-update del hysteria default >/dev/null 2>&1
    rm -f "$INIT_FILE" "$CONFD_FILE" "$BIN_PATH" "$LOG_FILE"
    rm -rf "$CONF_DIR"
    info "已卸载完成"
    UNINSTALLED=1
    return 0
}

menu() {
    UNINSTALLED=0
    while :; do
        printf '\n'
        print_banner
        printf '  节点: %s (服务运行中可用 rc-service hysteria status 查看)\n' "$(hostname 2>/dev/null)"
        printf '\n'
        printf '  1. 重新配置(端口/密码/obfs)\n'
        printf '  2. 查看节点信息与分享链接\n'
        printf '  3. 重启服务\n'
        printf '  4. 服务状态\n'
        printf '  5. 查看日志(最近 30 行)\n'
        printf '  6. 升级 hysteria(保留配置)\n'
        printf '  7. 卸载\n'
        printf '  0. 退出\n'
        printf '\n'
        ask "请选择" "0"
        case "$ANSWER" in
            1) apply_config; pause ;;
            2) show_info; pause ;;
            3) rc-service hysteria restart; sleep 1; rc-service hysteria status; pause ;;
            4) rc-service hysteria status; pause ;;
            5) tail -n 30 "$LOG_FILE" 2>/dev/null || warn "日志不存在"; pause ;;
            6) upgrade; pause ;;
            7) uninstall; [ "$UNINSTALLED" -eq 1 ] && exit 0; pause ;;
            0) exit 0 ;;
            *) warn "无效选择" ;;
        esac
    done
}

# ---------------------------- 主流程 ----------------------------------------
main() {
    [ "$(id -u)" -eq 0 ] || die "请以 root 运行本脚本"

    case "$(uname -m)" in
        x86_64|amd64)   ARCH="amd64" ;;
        aarch64|arm64)  ARCH="arm64" ;;
        *) die "不支持的架构: $(uname -m)(仅支持 x86_64 / arm64)" ;;
    esac

    if [ -f "$STATE_FILE" ] && [ -x "$BIN_PATH" ]; then
        menu
        exit 0
    fi

    [ -f /etc/alpine-release ] || die "本脚本仅支持 Alpine 系统"

    print_banner
    step "环境检查"
    info "系统: Alpine $(cat /etc/alpine-release 2>/dev/null || echo '?')  架构: ${ARCH}"
    _mem="$(free 2>/dev/null | awk '$1=="Mem:"{print $2}')"
    if [ -n "$_mem" ] && [ "$_mem" -lt 60000 ] 2>/dev/null; then
        warn "内存不足 60MB,hysteria 运行约需 20MB,请注意"
    fi

    if apply_config; then
        info "安装完成!重新运行本脚本可进入管理菜单"
    fi
    exit 0
}

main "$@"
