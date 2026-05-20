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
