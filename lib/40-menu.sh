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
