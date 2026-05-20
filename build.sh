#!/usr/bin/env bash
#
# build.sh — 把 lib/*.sh 拼接成 frp-installer.sh
#
# 用法:
#   ./build.sh           # 生成 frp-installer.sh
#   ./build.sh --check   # 仅做语法/shellcheck 校验, 不写入产物
#

set -euo pipefail

cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"

LIB_DIR="lib"
OUT="frp-installer.sh"
TMP="${OUT}.tmp"

REQUIRED=(00-header.sh 10-common.sh 20-install.sh 30-runtime.sh 40-menu.sh 99-main.sh)

for f in "${REQUIRED[@]}"; do
    [[ -f "$LIB_DIR/$f" ]] || { echo "[build] 缺少模块: $LIB_DIR/$f" >&2; exit 1; }
done

mode="${1:-build}"

# 拼接: 第一个文件保留 shebang, 其余文件首行若是 shebang 则剥除
{
    first=1
    for f in $(printf '%s\n' "${REQUIRED[@]}" | sort); do
        if [[ $first -eq 1 ]]; then
            cat "$LIB_DIR/$f"
            first=0
        else
            echo ""
            sed -e '1{/^#!/d;}' "$LIB_DIR/$f"
        fi
    done
} > "$TMP"

# 语法校验
if ! bash -n "$TMP"; then
    echo "[build] 语法校验失败, 已放弃生成" >&2
    rm -f "$TMP"
    exit 1
fi

# shellcheck (可选)
if command -v shellcheck >/dev/null 2>&1; then
    if ! shellcheck "$TMP"; then
        echo "[build] shellcheck 校验失败, 已放弃生成" >&2
        rm -f "$TMP"
        exit 1
    fi
fi

if [[ "$mode" == "--check" ]]; then
    rm -f "$TMP"
    echo "[build] check OK"
    exit 0
fi

mv "$TMP" "$OUT"
chmod +x "$OUT"
echo "[build] 已生成 $OUT  ($(wc -l <"$OUT" | tr -d ' ') 行)"
