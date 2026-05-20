# frp-auto-install

[![CI](https://github.com/frain1219/frp-auto-install/actions/workflows/ci.yml/badge.svg)](https://github.com/frain1219/frp-auto-install/actions/workflows/ci.yml)
[![Release](https://github.com/frain1219/frp-auto-install/actions/workflows/release.yml/badge.svg)](https://github.com/frain1219/frp-auto-install/releases/latest)

一个一键安装与运维 [frp](https://github.com/fatedier/frp) 的 Bash 脚本。无运维经验也能在 1 分钟内完成内网穿透部署。

参考官方文档: https://gofrp.org/zh-cn/docs/

## 特性

- **角色二选一**: 服务端 (`frps`) / 客户端 (`frpc`),同一份脚本两端通用
- **自动下载最新版**: 启动时通过 GitHub API 获取最新 release,失败时回退到内置版本
- **自动生成强随机 token**: 32 位字母数字,服务端启用 Dashboard 时同时生成 16 位管理员密码
- **官方 TOML 配置**: 使用 frp 当前推荐的 TOML 格式 (旧版 INI 已废弃)
- **systemd 集成**: 自动写入 unit 文件,一键开机自启
- **再次运行进入管理菜单**: 暂停 / 启动 / 重启 / 卸载 / 升级 / 改密码 / 改穿透规则 / 开关自启
- **客户端穿透规则可视化管理**: 列表展示,支持增删改

## 适用范围

- Linux + systemd (Ubuntu / Debian / CentOS / Rocky / Alma 等)
- 架构: amd64 / arm64 / arm / 386
- 不支持 macOS / Windows / 无 systemd 的精简发行版

## 快速开始

### 一行下载并运行

每次 main 分支推送都会通过 GitHub Actions 自动构建并发布到 `latest` release,可直接下载使用:

```bash
curl -fsSL https://github.com/frain1219/frp-auto-install/releases/latest/download/frp-installer.sh -o frp-installer.sh
sudo bash frp-installer.sh
```

或者一行流式执行:

```bash
curl -fsSL https://github.com/frain1219/frp-auto-install/releases/latest/download/frp-installer.sh | sudo bash
```

### 服务端 (拥有公网 IP 的机器)

```bash
sudo bash frp-installer.sh
# 选择 "1) 服务端"
# 按提示选择端口与是否启用 Dashboard
# 安装完成后会高亮打印: 监听端口 / token / Dashboard 地址账号密码
```

### 客户端 (内网机器)

```bash
sudo bash frp-installer.sh
# 选择 "2) 客户端"
# 输入服务端 IP / 端口 / token
# 逐条录入需要穿透的端口规则 (示例: 名称=ssh, 协议=tcp, 本地=127.0.0.1:22, 远程=6000)
```

### 再次运行进入管理菜单

```bash
sudo bash frp-installer.sh
# 或直接键入 (安装后自动建立软链):
sudo frp-installer
```

会先打印当前状态 (角色 / 版本 / 运行状态 / 开机自启状态 / 配置关键信息),然后展示菜单:

```
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
```

## 文件位置

| 路径 | 用途 |
|---|---|
| `/usr/local/frp/frps` 或 `frpc`        | frp 二进制 |
| `/usr/local/frp/frps.toml` 或 `frpc.toml` | 配置文件 |
| `/usr/local/frp/.frp-meta`             | 脚本写入的角色/版本元数据 |
| `/etc/systemd/system/frps.service`     | 服务端 systemd unit |
| `/etc/systemd/system/frpc.service`     | 客户端 systemd unit |
| `/usr/local/bin/frp-installer`         | 软链到本脚本,方便直接键入命令 |

## 环境变量

| 变量 | 说明 |
|---|---|
| `DOWNLOAD_MIRROR` | GitHub 下载镜像前缀,如 `https://ghproxy.com/`。默认直连 GitHub |

示例: `DOWNLOAD_MIRROR=https://ghproxy.com/ sudo -E bash frp-installer.sh`

## 自更新脚本配置

`menu 5) 更新本脚本` 默认未启用。如需启用,请编辑脚本顶部:

```bash
SCRIPT_REMOTE_URL="https://raw.githubusercontent.com/<your-user>/frp-auto-install/main/frp-installer.sh"
```

## 安全注意

- 安装完成时会以醒目方式打印 token / Dashboard 密码,**仅显示一次**,请立即保存
- 服务端的 `auth.token` 必须与所有客户端的 `auth.token` 完全一致
- 修改服务端 token 后需同步修改所有客户端的 token,否则连接会失败

## 故障排查

```bash
# 看服务状态与最近日志
systemctl status frps   # 或 frpc

# 看完整日志
journalctl -u frps -n 200 --no-pager

# 检查端口监听
ss -tnlp | grep frps
```

## 开发者构建

源码按职责拆在 [lib/](lib/) 下,通过 [build.sh](build.sh) 拼接成单文件 [frp-installer.sh](frp-installer.sh) 作为发布产物。终端用户不需要这一步,直接拉单文件即可运行。

```
lib/
├── 00-header.sh    # shebang / 全局常量 / 颜色
├── 10-common.sh    # 日志 / 交互 / 环境检查 / 架构识别 / TOML 读写 / 元数据
├── 20-install.sh   # 版本与下载 / 服务端 & 客户端配置 / 安装流程
├── 30-runtime.sh   # systemd unit / proxies 解析 / 状态展示
├── 40-menu.sh      # 各运维操作 / 穿透规则增删改 / 主菜单循环
└── 99-main.sh      # main 入口
```

构建命令:

```bash
./build.sh           # 重新生成 frp-installer.sh
./build.sh --check   # 仅做语法 + shellcheck 校验, 不写入产物
```

提交 PR 时请同时提交 `lib/` 修改与 `frp-installer.sh` 重新生成的产物。

## 许可证

MIT
