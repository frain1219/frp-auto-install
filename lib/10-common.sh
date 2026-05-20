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
