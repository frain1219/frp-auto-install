#!/usr/bin/env bash
#
# frp-installer.sh — frp 自动化安装与运维脚本
# 参考文档: https://gofrp.org/zh-cn/docs/
# 仓库:     https://github.com/fatedier/frp
#
# 用法:
#   sudo bash frp-installer.sh              # 首次运行进入安装向导, 已安装则进入管理菜单
#

set -o pipefail

# ===== 全局常量 =====
INSTALL_DIR="/usr/local/frp"
META_FILE="${INSTALL_DIR}/.frp-meta"
SYSTEMD_DIR="/etc/systemd/system"
BIN_LINK="/usr/local/bin/frp-installer"

# 远程脚本地址(留空则"更新脚本"提示未配置), 用户可自行修改为自己仓库的 raw 链接
SCRIPT_REMOTE_URL=""

# 下载镜像前缀(为空则直连 GitHub). 国内可设为 "https://ghproxy.com/"
DOWNLOAD_MIRROR="${DOWNLOAD_MIRROR:-}"

# 当 GitHub API 取版本失败时的回退版本
FALLBACK_VERSION="0.68.1"

# ===== 颜色 =====
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi

# ===== 日志 =====
log_info()  { printf '%s[INFO]%s  %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
log_warn()  { printf '%s[WARN]%s  %s\n'  "$C_YELLOW" "$C_RESET" "$*"; }
log_error() { printf '%s[ERROR]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
log_step()  { printf '\n%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }

print_kv() { printf '  %s%-22s%s : %s\n' "$C_CYAN" "$1" "$C_RESET" "$2"; }

print_banner() {
    printf '\n%s%s%s\n' "$C_YELLOW$C_BOLD" "▲ 请妥善保存以下信息，仅在安装完成时显示一次！" "$C_RESET"
    printf '%s%s%s\n\n' "$C_YELLOW" "──────────────────────────────────────────────" "$C_RESET"
}

# ===== 通用交互 =====
confirm() {
    # confirm "提示语" [默认 y|n]
    local prompt="$1" default="${2:-n}" reply
    local hint="[y/N]"
    [[ "$default" == "y" ]] && hint="[Y/n]"
    read -r -p "$prompt $hint " reply || true
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy]$ ]]
}

ask() {
    # ask "提示语" "默认值"  → echo 用户输入(允许空, 自动回退默认值)
    local prompt="$1" default="${2:-}" reply
    if [[ -n "$default" ]]; then
        read -r -p "$prompt [默认: $default]: " reply || true
        echo "${reply:-$default}"
    else
        read -r -p "$prompt: " reply || true
        echo "$reply"
    fi
}

ask_required() {
    # 必填项, 空则重复询问
    local prompt="$1" reply
    while :; do
        read -r -p "$prompt: " reply || true
        [[ -n "$reply" ]] && { echo "$reply"; return; }
        log_warn "该项不可为空, 请重新输入"
    done
}

ask_port() {
    # 端口必须为 1-65535
    local prompt="$1" default="${2:-}" reply
    while :; do
        reply=$(ask "$prompt" "$default")
        if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= 65535 )); then
            echo "$reply"; return
        fi
        log_warn "请输入合法端口号 (1-65535)"
    done
}

# ===== 环境检查 =====
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_warn "需要 root 权限, 正在使用 sudo 重新执行..."
        exec sudo -E bash "$0" "$@"
    fi
}

check_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        log_error "未检测到 systemctl, 本脚本仅支持 systemd 管理的 Linux 系统"
        exit 1
    fi
}

check_deps() {
    local missing=()
    for cmd in curl tar grep sed awk; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        log_error "缺少依赖命令: ${missing[*]}, 请先安装"
        exit 1
    fi
}

# ===== 架构识别 =====
detect_arch() {
    local m
    m=$(uname -m)
    case "$m" in
        x86_64|amd64)        echo "amd64" ;;
        aarch64|arm64)       echo "arm64" ;;
        armv7l|armv6l|armhf) echo "arm" ;;
        i386|i686)           echo "386" ;;
        *)
            log_error "不支持的 CPU 架构: $m"
            exit 1
            ;;
    esac
}

# ===== 随机字符串 =====
gen_random() {
    # gen_random [长度=32]
    local len="${1:-32}"
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
}

# ===== TOML 简易读写(仅针对脚本自己写入的简单 key=value 行) =====
read_toml_value() {
    # read_toml_value <文件> <key>
    local file="$1" key="$2"
    [[ -f "$file" ]] || { echo ""; return; }
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null \
        | head -n1 \
        | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//; s/^\"//; s/\"\$//; s/[[:space:]]+\$//"
}

update_toml_value() {
    # update_toml_value <文件> <key> <新值> [是否带引号(yes|no), 默认 yes]
    local file="$1" key="$2" val="$3" quoted="${4:-yes}"
    local replacement
    if [[ "$quoted" == "yes" ]]; then
        replacement="${key} = \"${val}\""
    else
        replacement="${key} = ${val}"
    fi
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
        # 用 | 作分隔符避免 / 在值里冲突
        sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${replacement}|" "$file"
    else
        printf '%s\n' "$replacement" >>"$file"
    fi
}

# ===== 元数据读写 =====
write_meta() {
    # write_meta <role> <version>
    local role="$1" version="$2"
    cat >"$META_FILE" <<EOF
ROLE=$role
VERSION=$version
INSTALL_TIME=$(date -Iseconds)
EOF
}

load_meta() {
    [[ -f "$META_FILE" ]] || return 1
    # shellcheck disable=SC1090
    source "$META_FILE"
    return 0
}

# ===== 版本与下载 =====
fetch_latest_version() {
    local ver=""
    ver=$(curl -fsSL --max-time 10 https://api.github.com/repos/fatedier/frp/releases/latest 2>/dev/null \
        | grep -m1 -oE '"tag_name"[[:space:]]*:[[:space:]]*"v[^"]+"' \
        | sed -E 's/.*"v([^"]+)".*/\1/')
    if [[ -z "$ver" ]]; then
        log_warn "GitHub API 取最新版本失败, 回退到内置版本 v${FALLBACK_VERSION}"
        ver="$FALLBACK_VERSION"
    fi
    echo "$ver"
}

download_and_extract() {
    # download_and_extract <version> <role>
    # 下载并解压, 仅保留所需角色二进制到 INSTALL_DIR
    local version="$1" role="$2"
    local arch tarball url tmp_dir extract_dir bin_name
    arch=$(detect_arch)
    tarball="frp_${version}_linux_${arch}.tar.gz"
    url="${DOWNLOAD_MIRROR}https://github.com/fatedier/frp/releases/download/v${version}/${tarball}"

    [[ "$role" == "server" ]] && bin_name="frps" || bin_name="frpc"

    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN

    log_step "下载 frp v${version} (linux/${arch})"
    log_info "下载地址: $url"
    if ! curl -fL --progress-bar -o "$tmp_dir/$tarball" "$url"; then
        log_error "下载失败, 请检查网络或设置 DOWNLOAD_MIRROR 环境变量后重试"
        return 1
    fi

    log_info "解压中..."
    tar -xzf "$tmp_dir/$tarball" -C "$tmp_dir" || { log_error "解压失败"; return 1; }
    extract_dir="$tmp_dir/frp_${version}_linux_${arch}"
    [[ -d "$extract_dir" ]] || { log_error "解压目录不存在: $extract_dir"; return 1; }

    mkdir -p "$INSTALL_DIR"
    install -m 0755 "$extract_dir/$bin_name" "$INSTALL_DIR/$bin_name" \
        || { log_error "安装二进制失败"; return 1; }
    log_info "已安装 $bin_name 到 $INSTALL_DIR/$bin_name"
}

# ===== 服务端配置 =====
write_frps_config() {
    # write_frps_config <bindPort> <token> <enable_dashboard> [dash_port] [dash_user] [dash_pass]
    local bind_port="$1" token="$2" enable_dash="$3"
    local dash_port="${4:-}" dash_user="${5:-}" dash_pass="${6:-}"
    local cfg="${INSTALL_DIR}/frps.toml"
    {
        echo "bindPort = ${bind_port}"
        echo ""
        echo "auth.method = \"token\""
        echo "auth.token = \"${token}\""
        if [[ "$enable_dash" == "yes" ]]; then
            echo ""
            echo "webServer.addr = \"0.0.0.0\""
            echo "webServer.port = ${dash_port}"
            echo "webServer.user = \"${dash_user}\""
            echo "webServer.password = \"${dash_pass}\""
        fi
    } >"$cfg"
    chmod 0644 "$cfg"
}

install_server() {
    log_step "服务端安装向导"
    local bind_port token
    bind_port=$(ask_port "frp 服务端监听端口" "7000")
    token=$(gen_random 32)

    local enable_dash="no" dash_port="" dash_user="" dash_pass=""
    if confirm "是否启用 Dashboard (Web 管理面板)?" "y"; then
        enable_dash="yes"
        dash_port=$(ask_port "Dashboard 端口" "7500")
        dash_user="admin"
        dash_pass=$(gen_random 16)
    fi

    local version
    version=$(fetch_latest_version)
    download_and_extract "$version" "server" || exit 1

    write_frps_config "$bind_port" "$token" "$enable_dash" "$dash_port" "$dash_user" "$dash_pass"
    write_systemd_unit "server"
    write_meta "server" "$version"
    create_self_link

    systemctl daemon-reload
    if confirm "是否立即启动 frps 并设置开机自启?" "y"; then
        systemctl enable --now frps
        sleep 1
        systemctl --no-pager --lines=0 status frps || true
    fi

    print_banner
    print_kv "角色"        "服务端 (frps)"
    print_kv "版本"        "v${version}"
    print_kv "监听端口"    "${bind_port}"
    print_kv "认证 token"  "${token}"
    if [[ "$enable_dash" == "yes" ]]; then
        local ip
        ip=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || echo "<服务器公网IP>")
        print_kv "Dashboard"     "http://${ip}:${dash_port}"
        print_kv "Dashboard 用户" "${dash_user}"
        print_kv "Dashboard 密码" "${dash_pass}"
    fi
    print_kv "配置文件"    "${INSTALL_DIR}/frps.toml"
    print_kv "服务名"      "frps.service"
    echo ""
    log_info "客户端连接时需使用 IP/域名 + 端口 ${bind_port} + 上述 token"
    log_info "再次运行本脚本(或执行 frp-installer)进入管理菜单"
}

# ===== 客户端配置 =====
write_frpc_header() {
    # write_frpc_header <serverAddr> <serverPort> <token>
    local cfg="${INSTALL_DIR}/frpc.toml"
    {
        echo "serverAddr = \"$1\""
        echo "serverPort = $2"
        echo ""
        echo "auth.method = \"token\""
        echo "auth.token = \"$3\""
    } >"$cfg"
    chmod 0644 "$cfg"
}

append_proxy() {
    # append_proxy <name> <type> <localIP> <localPort> <remotePort>
    local cfg="${INSTALL_DIR}/frpc.toml"
    {
        echo ""
        echo "[[proxies]]"
        echo "name = \"$1\""
        echo "type = \"$2\""
        echo "localIP = \"$3\""
        echo "localPort = $4"
        echo "remotePort = $5"
    } >>"$cfg"
}

prompt_one_proxy() {
    # 交互录入一条 proxy, 写入配置. 失败返回非 0.
    local name proto local_ip local_port remote_port
    name=$(ask_required "  规则名称(英文/数字, 例如 ssh)")
    while :; do
        proto=$(ask "  协议类型(tcp/udp)" "tcp")
        [[ "$proto" =~ ^(tcp|udp)$ ]] && break
        log_warn "  协议仅支持 tcp 或 udp"
    done
    local_ip=$(ask "  本地服务 IP" "127.0.0.1")
    local_port=$(ask_port "  本地服务端口")
    remote_port=$(ask_port "  服务端暴露端口")
    append_proxy "$name" "$proto" "$local_ip" "$local_port" "$remote_port"
    log_info "  已添加规则: ${name} (${proto}) ${local_ip}:${local_port} → 服务端:${remote_port}"
}

install_client() {
    log_step "客户端安装向导"
    local server_addr server_port token
    server_addr=$(ask_required "服务端 IP 或域名")
    server_port=$(ask_port "服务端端口" "7000")
    token=$(ask_required "服务端 token (与服务端 frps.toml 中 auth.token 一致)")

    local version
    version=$(fetch_latest_version)
    download_and_extract "$version" "client" || exit 1

    mkdir -p "$INSTALL_DIR"
    write_frpc_header "$server_addr" "$server_port" "$token"

    log_step "录入需要穿透的端口规则 (至少一条)"
    prompt_one_proxy
    while confirm "是否继续添加下一条规则?" "n"; do
        prompt_one_proxy
    done

    write_systemd_unit "client"
    write_meta "client" "$version"
    create_self_link

    systemctl daemon-reload
    if confirm "是否立即启动 frpc 并设置开机自启?" "y"; then
        systemctl enable --now frpc
        sleep 1
        systemctl --no-pager --lines=0 status frpc || true
    fi

    print_banner
    print_kv "角色"      "客户端 (frpc)"
    print_kv "版本"      "v${version}"
    print_kv "服务端"    "${server_addr}:${server_port}"
    print_kv "配置文件"  "${INSTALL_DIR}/frpc.toml"
    print_kv "服务名"    "frpc.service"
    echo ""
    log_info "再次运行本脚本(或执行 frp-installer)进入管理菜单"
}

# ===== 安装入口 =====
install_flow() {
    log_step "frp 自动化安装向导"
    echo "  1) 服务端 (frps) - 部署在拥有公网 IP 的机器"
    echo "  2) 客户端 (frpc) - 部署在内网服务所在的机器"
    local role_choice
    while :; do
        role_choice=$(ask "请选择本机角色" "")
        case "$role_choice" in
            1) install_server; break ;;
            2) install_client; break ;;
            *) log_warn "请输入 1 或 2" ;;
        esac
    done
}


# ===== systemd unit =====
write_systemd_unit() {
    # write_systemd_unit <server|client>
    local role="$1"
    local svc bin desc
    if [[ "$role" == "server" ]]; then
        svc="frps"; bin="frps"; desc="frp server"
    else
        svc="frpc"; bin="frpc"; desc="frp client"
    fi
    cat >"${SYSTEMD_DIR}/${svc}.service" <<EOF
[Unit]
Description = ${desc}
After = network.target syslog.target
Wants = network.target

[Service]
Type = simple
Restart = on-failure
RestartSec = 5
ExecStart = ${INSTALL_DIR}/${bin} -c ${INSTALL_DIR}/${bin}.toml

[Install]
WantedBy = multi-user.target
EOF
    chmod 0644 "${SYSTEMD_DIR}/${svc}.service"
}

create_self_link() {
    # 把脚本本体软链到 /usr/local/bin/frp-installer 方便用户直接键入命令
    local self
    self=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [[ -f "$self" ]]; then
        ln -sf "$self" "$BIN_LINK" 2>/dev/null || true
    fi
}

service_name_from_meta() {
    [[ "${ROLE:-}" == "server" ]] && echo "frps" || echo "frpc"
}

# ===== proxies 解析(仅客户端 frpc.toml) =====
list_proxies() {
    # 输出: 索引<TAB>name<TAB>type<TAB>localIP<TAB>localPort<TAB>remotePort
    local cfg="${INSTALL_DIR}/frpc.toml"
    [[ -f "$cfg" ]] || return 0
    awk '
        BEGIN { idx=0; in_block=0 }
        /^\[\[proxies\]\]/ {
            if (in_block) {
                printf "%d\t%s\t%s\t%s\t%s\t%s\n", idx, name, type, lip, lport, rport
                idx++
            } else { idx=1 }
            in_block=1; name=""; type=""; lip="127.0.0.1"; lport=""; rport=""
            next
        }
        in_block && /^[[:space:]]*name[[:space:]]*=/        { gsub(/.*=[[:space:]]*"?|"[[:space:]]*$/, ""); name=$0; next }
        in_block && /^[[:space:]]*type[[:space:]]*=/        { gsub(/.*=[[:space:]]*"?|"[[:space:]]*$/, ""); type=$0; next }
        in_block && /^[[:space:]]*localIP[[:space:]]*=/     { gsub(/.*=[[:space:]]*"?|"[[:space:]]*$/, ""); lip=$0; next }
        in_block && /^[[:space:]]*localPort[[:space:]]*=/   { gsub(/.*=[[:space:]]*/, ""); lport=$0; next }
        in_block && /^[[:space:]]*remotePort[[:space:]]*=/  { gsub(/.*=[[:space:]]*/, ""); rport=$0; next }
        END {
            if (in_block) {
                printf "%d\t%s\t%s\t%s\t%s\t%s\n", idx, name, type, lip, lport, rport
            }
        }
    ' "$cfg"
}

print_proxies_table() {
    local rows
    rows=$(list_proxies)
    if [[ -z "$rows" ]]; then
        printf '  %s(暂无穿透规则)%s\n' "$C_YELLOW" "$C_RESET"
        return
    fi
    printf '  %s%-4s %-16s %-6s %-18s %-10s %-10s%s\n' \
        "$C_CYAN" "#" "名称" "协议" "本地IP" "本地端口" "远程端口" "$C_RESET"
    while IFS=$'\t' read -r idx name type lip lport rport; do
        printf '  %-4s %-16s %-6s %-18s %-10s %-10s\n' "$idx" "$name" "$type" "$lip" "$lport" "$rport"
    done <<< "$rows"
}

rebuild_frpc_with_proxies() {
    # rebuild_frpc_with_proxies <serverAddr> <serverPort> <token> <proxies_tsv>
    # proxies_tsv 每行: name<TAB>type<TAB>localIP<TAB>localPort<TAB>remotePort
    local server_addr="$1" server_port="$2" token="$3" tsv="$4"
    write_frpc_header "$server_addr" "$server_port" "$token"
    while IFS=$'\t' read -r name type lip lport rport; do
        [[ -z "$name" ]] && continue
        append_proxy "$name" "$type" "$lip" "$lport" "$rport"
    done <<< "$tsv"
}

# ===== 状态展示 =====
show_status() {
    load_meta || { log_error "缺少元数据文件 ${META_FILE}"; exit 1; }
    local svc bin cfg
    svc=$(service_name_from_meta)
    bin="${INSTALL_DIR}/${svc}"
    cfg="${INSTALL_DIR}/${svc}.toml"

    log_step "当前 frp 运行状态"

    local meta_ver bin_ver
    meta_ver="${VERSION:-未知}"
    if [[ -x "$bin" ]]; then
        bin_ver=$("$bin" -v 2>/dev/null || echo "无法读取")
    else
        bin_ver="二进制文件缺失"
    fi
    print_kv "角色"        "$( [[ "$ROLE" == "server" ]] && echo "服务端 (frps)" || echo "客户端 (frpc)" )"
    print_kv "frp 版本"    "v${meta_ver}  (二进制: ${bin_ver})"
    print_kv "安装时间"    "${INSTALL_TIME:-未知}"

    local active enabled
    active=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
    enabled=$(systemctl is-enabled "$svc" 2>/dev/null || echo "unknown")
    local active_disp enabled_disp
    case "$active" in
        active)   active_disp="${C_GREEN}运行中${C_RESET}" ;;
        inactive) active_disp="${C_YELLOW}已停止${C_RESET}" ;;
        failed)   active_disp="${C_RED}失败${C_RESET}" ;;
        *)        active_disp="${active}" ;;
    esac
    case "$enabled" in
        enabled)  enabled_disp="${C_GREEN}已启用${C_RESET}" ;;
        disabled) enabled_disp="${C_YELLOW}未启用${C_RESET}" ;;
        *)        enabled_disp="${enabled}" ;;
    esac
    print_kv "运行状态"    "$active_disp"
    print_kv "开机自启"    "$enabled_disp"
    print_kv "服务名"      "${svc}.service"
    print_kv "配置文件"    "${cfg}"

    echo ""
    if [[ "$ROLE" == "server" ]]; then
        local bind_port token dash_port dash_user dash_pass
        bind_port=$(read_toml_value "$cfg" "bindPort")
        token=$(read_toml_value "$cfg" "auth.token")
        dash_port=$(read_toml_value "$cfg" "webServer.port")
        dash_user=$(read_toml_value "$cfg" "webServer.user")
        dash_pass=$(read_toml_value "$cfg" "webServer.password")
        log_step "服务端配置"
        print_kv "监听端口"    "${bind_port:-未配置}"
        print_kv "认证 token"  "${token:-未配置}"
        if [[ -n "$dash_port" ]]; then
            print_kv "Dashboard 端口" "${dash_port}"
            print_kv "Dashboard 用户" "${dash_user}"
            print_kv "Dashboard 密码" "${dash_pass}"
        else
            print_kv "Dashboard"    "未启用"
        fi
    else
        local server_addr server_port token
        server_addr=$(read_toml_value "$cfg" "serverAddr")
        server_port=$(read_toml_value "$cfg" "serverPort")
        token=$(read_toml_value "$cfg" "auth.token")
        log_step "客户端配置"
        print_kv "服务端地址"  "${server_addr:-未配置}"
        print_kv "服务端端口"  "${server_port:-未配置}"
        print_kv "认证 token"  "${token:-未配置}"
        echo ""
        log_step "穿透规则"
        print_proxies_table
    fi
}

# ===== 菜单各操作 =====
op_stop() {
    local svc; svc=$(service_name_from_meta)
    if systemctl stop "$svc"; then log_info "已停止 ${svc}"; else log_error "停止 ${svc} 失败"; fi
}
op_start() {
    local svc; svc=$(service_name_from_meta)
    if systemctl start "$svc"; then log_info "已启动 ${svc}"; else log_error "启动 ${svc} 失败"; fi
}
op_restart() {
    local svc; svc=$(service_name_from_meta)
    if systemctl restart "$svc"; then log_info "已重启 ${svc}"; else log_error "重启 ${svc} 失败"; fi
}
op_enable() {
    local svc; svc=$(service_name_from_meta)
    if systemctl enable "$svc"; then log_info "已开启开机自启"; else log_error "操作失败"; fi
}
op_disable() {
    local svc; svc=$(service_name_from_meta)
    if systemctl disable "$svc"; then log_info "已关闭开机自启"; else log_error "操作失败"; fi
}

op_uninstall() {
    log_warn "即将卸载 frp (保留本脚本):"
    log_warn "  - 停止并禁用 systemd 服务"
    log_warn "  - 删除 ${INSTALL_DIR}/ 整个目录"
    log_warn "  - 删除 ${SYSTEMD_DIR}/frps.service 与 frpc.service"
    confirm "确认卸载?" "n" || { log_info "已取消"; return; }

    local svc; svc=$(service_name_from_meta)
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/frps.service" "${SYSTEMD_DIR}/frpc.service"
    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    rm -f "$BIN_LINK"
    log_info "卸载完成. 脚本本体仍保留, 可再次运行重新安装"
    exit 0
}

op_update_script() {
    if [[ -z "$SCRIPT_REMOTE_URL" ]]; then
        log_warn "未配置脚本远程更新地址 (SCRIPT_REMOTE_URL), 跳过"
        log_warn "请在脚本顶部修改 SCRIPT_REMOTE_URL 为你的 raw 链接, 例如:"
        log_warn "  https://raw.githubusercontent.com/<user>/frp-auto-install/main/frp-installer.sh"
        return
    fi
    local self tmp
    self=$(readlink -f "$0" 2>/dev/null || echo "$0")
    tmp=$(mktemp)
    log_info "从 $SCRIPT_REMOTE_URL 拉取最新脚本..."
    if curl -fsSL --max-time 30 -o "$tmp" "$SCRIPT_REMOTE_URL"; then
        if head -n1 "$tmp" | grep -q '^#!'; then
            install -m 0755 "$tmp" "$self"
            rm -f "$tmp"
            log_info "脚本已更新, 请重新运行: bash $self"
            exit 0
        else
            log_error "下载内容不像合法脚本(无 shebang), 已放弃覆盖"
            rm -f "$tmp"
        fi
    else
        log_error "下载失败"
        rm -f "$tmp"
    fi
}

op_update_frp() {
    load_meta || return
    local new_ver svc
    svc=$(service_name_from_meta)
    new_ver=$(fetch_latest_version)
    log_info "当前已安装版本: v${VERSION}"
    log_info "GitHub 最新版本: v${new_ver}"
    if [[ "$new_ver" == "$VERSION" ]]; then
        confirm "版本相同, 是否仍要重新下载?" "n" || return
    else
        confirm "确认升级到 v${new_ver}?" "y" || return
    fi
    download_and_extract "$new_ver" "$ROLE" || { log_error "升级失败"; return; }
    write_meta "$ROLE" "$new_ver"
    systemctl restart "$svc"
    log_info "已升级到 v${new_ver} 并重启 ${svc}"
}

op_change_token() {
    load_meta || return
    local svc cfg new_token
    svc=$(service_name_from_meta)
    cfg="${INSTALL_DIR}/${svc}.toml"
    if [[ "$ROLE" == "server" ]]; then
        if confirm "服务端: 自动生成新随机 token?" "y"; then
            new_token=$(gen_random 32)
        else
            new_token=$(ask_required "请输入新 token")
        fi
    else
        new_token=$(ask_required "请输入新 token (必须与服务端一致)")
    fi
    update_toml_value "$cfg" "auth.token" "$new_token" "yes"
    systemctl restart "$svc"
    log_info "token 已更新并重启 ${svc}"
    print_kv "新 token" "$new_token"
    [[ "$ROLE" == "server" ]] && log_warn "请同步修改所有客户端的 auth.token, 否则连接将失败"
}

# ===== 客户端 proxies 管理 =====
collect_existing_proxies_tsv() {
    # 转成 name<TAB>type<TAB>lip<TAB>lport<TAB>rport (去掉首列索引)
    list_proxies | awk -F'\t' 'NF>=6 {print $2"\t"$3"\t"$4"\t"$5"\t"$6}'
}

op_change_proxies() {
    load_meta || return
    if [[ "$ROLE" != "client" ]]; then
        log_warn "仅客户端支持修改穿透规则"
        return
    fi
    local cfg="${INSTALL_DIR}/frpc.toml"
    while :; do
        echo ""
        log_step "穿透规则管理"
        print_proxies_table
        echo ""
        echo "  1) 新增一条"
        echo "  2) 删除一条"
        echo "  3) 修改一条"
        echo "  0) 返回上层菜单"
        local choice
        choice=$(ask "请选择" "0")
        case "$choice" in
            1) proxy_add ;;
            2) proxy_delete ;;
            3) proxy_edit ;;
            0) return ;;
            *) log_warn "无效选项" ;;
        esac
    done
}

reload_client_after_proxy_change() {
    local server_addr server_port token tsv
    local cfg="${INSTALL_DIR}/frpc.toml"
    server_addr=$(read_toml_value "$cfg" "serverAddr")
    server_port=$(read_toml_value "$cfg" "serverPort")
    token=$(read_toml_value "$cfg" "auth.token")
    tsv="$1"
    rebuild_frpc_with_proxies "$server_addr" "$server_port" "$token" "$tsv"
    systemctl restart frpc
    log_info "已写入新规则并重启 frpc"
}

proxy_add() {
    log_info "新增一条穿透规则"
    local tsv
    tsv=$(collect_existing_proxies_tsv)
    local name proto lip lport rport
    name=$(ask_required "  规则名称")
    while :; do
        proto=$(ask "  协议(tcp/udp)" "tcp")
        [[ "$proto" =~ ^(tcp|udp)$ ]] && break
        log_warn "  协议仅支持 tcp 或 udp"
    done
    lip=$(ask "  本地服务 IP" "127.0.0.1")
    lport=$(ask_port "  本地服务端口")
    rport=$(ask_port "  服务端暴露端口")
    tsv+=$'\n'"${name}	${proto}	${lip}	${lport}	${rport}"
    reload_client_after_proxy_change "$tsv"
}

proxy_delete() {
    local rows; rows=$(list_proxies)
    [[ -z "$rows" ]] && { log_warn "暂无规则可删除"; return; }
    local idx
    idx=$(ask "请输入要删除规则的 #")
    [[ "$idx" =~ ^[0-9]+$ ]] || { log_warn "无效编号"; return; }
    confirm "确认删除规则 #$idx?" "n" || return
    local new_tsv
    new_tsv=$(echo "$rows" | awk -F'\t' -v target="$idx" '$1!=target {print $2"\t"$3"\t"$4"\t"$5"\t"$6}')
    reload_client_after_proxy_change "$new_tsv"
}

proxy_edit() {
    local rows; rows=$(list_proxies)
    [[ -z "$rows" ]] && { log_warn "暂无规则可修改"; return; }
    local idx
    idx=$(ask "请输入要修改规则的 #")
    [[ "$idx" =~ ^[0-9]+$ ]] || { log_warn "无效编号"; return; }
    local target
    target=$(echo "$rows" | awk -F'\t' -v t="$idx" '$1==t {print; exit}')
    [[ -z "$target" ]] && { log_warn "未找到 #$idx"; return; }
    local cur_name cur_type cur_lip cur_lport cur_rport
    IFS=$'\t' read -r _ cur_name cur_type cur_lip cur_lport cur_rport <<< "$target"
    log_info "当前: $cur_name ($cur_type) ${cur_lip}:${cur_lport} → 服务端:${cur_rport}"
    local name proto lip lport rport
    name=$(ask "  规则名称" "$cur_name")
    while :; do
        proto=$(ask "  协议(tcp/udp)" "$cur_type")
        [[ "$proto" =~ ^(tcp|udp)$ ]] && break
        log_warn "  协议仅支持 tcp 或 udp"
    done
    lip=$(ask "  本地服务 IP" "$cur_lip")
    lport=$(ask_port "  本地服务端口" "$cur_lport")
    rport=$(ask_port "  服务端暴露端口" "$cur_rport")
    local new_tsv
    new_tsv=$(echo "$rows" | awk -F'\t' -v t="$idx" -v n="$name" -v p="$proto" -v li="$lip" -v lp="$lport" -v rp="$rport" '
        $1==t { print n"\t"p"\t"li"\t"lp"\t"rp; next }
        { print $2"\t"$3"\t"$4"\t"$5"\t"$6 }
    ')
    reload_client_after_proxy_change "$new_tsv"
}

# ===== 主菜单循环 =====
manage_menu() {
    while :; do
        clear
        show_status
        echo ""
        log_step "管理菜单"
        cat <<EOM
  1) 暂停运行
  2) 启动运行
  3) 重启
  4) 卸载 (保留脚本)
  5) 更新本脚本
  6) 更新 frp 二进制
  7) 修改 token
  8) 修改穿透信息 (仅客户端)
  9) 开启开机自启
 10) 关闭开机自启
  0) 退出
EOM
        local choice
        choice=$(ask "请选择" "0")
        case "$choice" in
            1)  op_stop ;;
            2)  op_start ;;
            3)  op_restart ;;
            4)  op_uninstall ;;
            5)  op_update_script ;;
            6)  op_update_frp ;;
            7)  op_change_token ;;
            8)  op_change_proxies ;;
            9)  op_enable ;;
            10) op_disable ;;
            0)  log_info "再见"; exit 0 ;;
            *)  log_warn "无效选项: $choice" ;;
        esac
        echo ""
        read -r -p "按回车键继续..." _ || true
    done
}

# ===== main =====
main() {
    require_root "$@"
    check_systemd
    check_deps
    if [[ -f "$META_FILE" ]]; then
        load_meta
        manage_menu
    else
        install_flow
    fi
}

main "$@"
