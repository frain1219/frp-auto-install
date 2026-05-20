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

# ===== 服务端 Dashboard 与连接状态 =====
read_frps_config_full() {
    # 把 frps.toml 关键字段 echo 到全局变量, 供调用方使用
    local cfg="${INSTALL_DIR}/frps.toml"
    FRPS_BIND_PORT=$(read_toml_value "$cfg" "bindPort")
    FRPS_TOKEN=$(read_toml_value "$cfg" "auth.token")
    FRPS_DASH_PORT=$(read_toml_value "$cfg" "webServer.port")
    FRPS_DASH_USER=$(read_toml_value "$cfg" "webServer.user")
    FRPS_DASH_PASS=$(read_toml_value "$cfg" "webServer.password")
}

op_toggle_dashboard() {
    load_meta || return
    if [[ "$ROLE" != "server" ]]; then
        log_warn "仅服务端支持开关 Dashboard"
        return
    fi
    read_frps_config_full
    if [[ -n "$FRPS_DASH_PORT" ]]; then
        # 当前已启用 → 询问关闭
        log_info "Dashboard 当前已启用 (端口 ${FRPS_DASH_PORT})"
        confirm "确认关闭 Dashboard?" "n" || return
        write_frps_config "$FRPS_BIND_PORT" "$FRPS_TOKEN" "no"
        systemctl restart frps
        log_info "Dashboard 已关闭并重启 frps"
    else
        # 当前未启用 → 询问开启
        log_info "Dashboard 当前未启用"
        confirm "确认开启 Dashboard?" "y" || return
        local dash_port dash_user dash_pass
        dash_port=$(ask_port "Dashboard 端口" "7500")
        dash_user="admin"
        dash_pass=$(gen_random 16)
        write_frps_config "$FRPS_BIND_PORT" "$FRPS_TOKEN" "yes" "$dash_port" "$dash_user" "$dash_pass"
        systemctl restart frps
        log_info "Dashboard 已开启并重启 frps"
        local ip
        ip=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || echo "<服务器公网IP>")
        print_kv "Dashboard"     "http://${ip}:${dash_port}"
        print_kv "Dashboard 用户" "${dash_user}"
        print_kv "Dashboard 密码" "${dash_pass}"
        log_warn "请放行服务器防火墙的 ${dash_port} 端口"
    fi
}

dashboard_api_get() {
    # dashboard_api_get <path>  → echo 响应 body, 失败时返回非零
    # 复用 read_frps_config_full 已加载的 FRPS_DASH_* 变量
    local path="$1"
    curl -fsS --max-time 5 \
        -u "${FRPS_DASH_USER}:${FRPS_DASH_PASS}" \
        "http://127.0.0.1:${FRPS_DASH_PORT}${path}"
}

print_proxies_from_api() {
    # print_proxies_from_api <proto>
    # 解析 /api/proxy/<tcp|udp> 的 JSON 响应并打印表格
    local proto="$1" json
    json=$(dashboard_api_get "/api/proxy/${proto}") || { log_warn "  调用 ${proto} API 失败"; return; }
    if ! command -v jq >/dev/null 2>&1; then
        log_warn "  未安装 jq, 显示原始 JSON (建议: apt install jq):"
        echo "$json"
        return
    fi
    local count
    count=$(echo "$json" | jq -r '.proxies | length')
    if [[ "$count" == "0" || -z "$count" ]]; then
        printf '  %s(无 %s 类型在线 proxy)%s\n' "$C_YELLOW" "$proto" "$C_RESET"
        return
    fi
    printf '  %s%-16s %-8s %-12s %-10s %-12s %-12s%s\n' \
        "$C_CYAN" "名称" "状态" "远程端口" "连接数" "今日入站" "今日出站" "$C_RESET"
    echo "$json" | jq -r '
        .proxies[] |
        [
            .name,
            .status,
            (.conf.remotePort // "-" | tostring),
            (.curConns // 0 | tostring),
            (.todayTrafficIn // 0 | tostring),
            (.todayTrafficOut // 0 | tostring)
        ] | @tsv
    ' | while IFS=$'\t' read -r name status rport conns tin tout; do
        local status_disp
        case "$status" in
            online)  status_disp="${C_GREEN}online${C_RESET}" ;;
            offline) status_disp="${C_YELLOW}offline${C_RESET}" ;;
            *)       status_disp="$status" ;;
        esac
        printf '  %-16s %-17s %-12s %-10s %-12s %-12s\n' \
            "$name" "$status_disp" "$rport" "$conns" "$(human_bytes "$tin")" "$(human_bytes "$tout")"
    done
}

human_bytes() {
    # 简单字节转人类可读. 输入纯数字, 失败时原样输出.
    local b="${1:-0}"
    [[ "$b" =~ ^[0-9]+$ ]] || { echo "$b"; return; }
    if   (( b < 1024 ));         then echo "${b}B"
    elif (( b < 1048576 ));      then echo "$(( b / 1024 ))K"
    elif (( b < 1073741824 ));   then echo "$(( b / 1048576 ))M"
    else                              echo "$(( b / 1073741824 ))G"
    fi
}

op_show_connections() {
    load_meta || return
    if [[ "$ROLE" != "server" ]]; then
        log_warn "仅服务端支持查看连接状态 (Dashboard API)"
        return
    fi
    read_frps_config_full
    if [[ -z "$FRPS_DASH_PORT" ]]; then
        log_warn "Dashboard 未启用, 无法查询连接状态"
        log_warn "请先在管理菜单中开启 Dashboard"
        return
    fi
    if ! systemctl is-active --quiet frps; then
        log_warn "frps 未运行, 请先启动服务"
        return
    fi

    log_step "服务器信息"
    local info
    info=$(dashboard_api_get "/api/serverinfo") || { log_error "无法连接 Dashboard API"; return; }
    if command -v jq >/dev/null 2>&1; then
        print_kv "frp 版本"     "$(echo "$info" | jq -r '.version // "-"')"
        print_kv "在线客户端数" "$(echo "$info" | jq -r '.clientCounts // 0')"
        print_kv "活跃 proxy 数" "$(echo "$info" | jq -r '.proxyCounts // 0')"
        print_kv "总入站流量"   "$(human_bytes "$(echo "$info" | jq -r '.totalTrafficIn // 0')")"
        print_kv "总出站流量"   "$(human_bytes "$(echo "$info" | jq -r '.totalTrafficOut // 0')")"
    else
        log_warn "未安装 jq, 显示原始 JSON:"
        echo "$info"
    fi

    log_step "TCP Proxies"
    print_proxies_from_api "tcp"
    log_step "UDP Proxies"
    print_proxies_from_api "udp"
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
 11) 切换 Dashboard 开关 (仅服务端)
 12) 查看连接状态 (仅服务端, 需 Dashboard)
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
            11) op_toggle_dashboard ;;
            12) op_show_connections ;;
            0)  log_info "再见"; exit 0 ;;
            *)  log_warn "无效选项: $choice" ;;
        esac
        echo ""
        read -r -p "按回车键继续..." _ || true
    done
}
