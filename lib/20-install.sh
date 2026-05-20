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

