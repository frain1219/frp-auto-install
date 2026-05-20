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
