# 3X-UI Clean（纯净无广告版）

基于官方开源项目 [MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui) 构建的纯净无广告衍生版本（遵循 **GNU GPL v3.0** 协议）。

## 一、核心特性

1. **彻底移除推广广告与赞助组件（零远程广告请求）**：
   - 移除后端 `internal/web/service/panel/sponsor.go` 对 `MHSanaei/sponsors` 的定时外发请求及 `/sponsors`、`/sponsors/logo/:name` 接口。
   - 移除前端登录页底部广告位、仪表盘横幅广告位、侧边栏“赞助商（Sponsors）”菜单与页面、快捷键搜索项及侧边栏顶部“捐赠（Donate）”外链。
2. **100% 保留官方核心功能与数据兼容**：
   - 不修改任何 SQLite / PostgreSQL 数据库表结构，不修改 Xray-core 协议（VLESS / REALITY / XTLS-Vision 等）、入站管理、客户端与流量统计、订阅服务、Telegram Bot 或 Cloudflare Tunnel 兼容性。
3. **接管面板与 CLI 自更新通道（防覆盖）**：
   - 面板内置在线更新（`panel.go`）与 `x-ui` 命令行菜单更新均已指向 `chb1991/3x-ui-clean`，防止在面板点击更新后被覆盖回官方带广告版本。
4. **事务级安全升级、一致性热备与故障自动回滚**：
   - 升级前在临时目录预校验二进制与 SHA256，停机完成 SQLite WAL 一致性全量备份后才替换二进制；升级后自动执行服务与端口健康检查，一旦失败自动触发回滚恢复。

---

## 二、快速使用指南

### 1. 在线一键安装 / 现有面板无损切换为纯净版

> **安全机制**：若检测到 `/etc/x-ui/x-ui.db` 已存在，脚本会**自动进入原位无损升级模式**，完整保留现有数据库、面板端口、监听地址、`webBasePath`、SSL 配置及所有节点！

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chb1991/3x-ui-clean/main/scripts/install.sh)
```

或者直接执行升级脚本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chb1991/3x-ui-clean/main/scripts/update.sh)
```

### 2. 完全离线安装 / 离线升级

1. 从 [GitHub Releases](https://github.com/chb1991/3x-ui-clean/releases) 下载对应架构的离线完整包 `3x-ui-clean-vX.Y.Z-linux-amd64-offline.tar.gz` 及 `.sha256` 校验文件，上传至 VPS `/tmp`。
2. 在 VPS 上执行：

```bash
cd /tmp
sha256sum -c 3x-ui-clean-v*-linux-amd64-offline.tar.gz.sha256
tar -xzf 3x-ui-clean-v*-linux-amd64-offline.tar.gz
cd 3x-ui-clean-offline

# 全新安装或原位无损升级（自动识别是否已有 /etc/x-ui/x-ui.db）
bash scripts/install.sh --offline ./x-ui-linux-amd64.tar.gz
```

### 3. 备份与一键回滚

安装或升级后，`backup.sh` 与 `rollback.sh` 会自动安装至 `/usr/local/x-ui/scripts/`，并集成进 `x-ui` 命令：

```bash
# 创建一致性全量备份（保存至 /var/backups/x-ui/）
x-ui backup

# 停机刷新 WAL 后创建冷备份并在备份后自动重启
x-ui backup --stop-service --restart-after

# 交互式选择历史备份进行回滚（同时恢复旧版二进制与旧版数据库）
x-ui rollback

# 一键回滚至最近一次备份
x-ui rollback --latest
```

---

## 三、仓库目录结构

```text
3x-ui-clean/
├── .github/workflows/
│   ├── sync-and-release.yml   # 定时同步官方最新稳定版 Tag + 静态编译 + 发布 Release
│   └── ci-verify-patch.yml    # 验证补丁在官方最新 Release 与 main 分支上的兼容性
├── patches/
│   ├── remove-files.txt       # 物理移除的 11 个前后端广告/赞助专属文件清单
│   ├── callsites.patch        # 10 个调用点文件的最小化 3-way Patch
│   └── apply-clean.sh         # 构建预处理与零广告静态语义门禁脚本
├── scripts/
│   ├── install.sh             # 在线/离线二合一安装脚本（检测到现有 DB 自动转无损升级）
│   ├── update.sh              # 事务级安全升级脚本（含预检、自动备份、健康检查、失败回滚）
│   ├── backup.sh              # SQLite WAL 安全全量备份脚本
│   └── rollback.sh            # 交互式/自动一键回滚脚本
├── install.sh                 # 根目录安装入口
├── update.sh                  # 根目录升级入口（兼容 Web 面板内置在线更新调用）
├── x-ui.sh                    # 纯净版 CLI 管理脚本（含 backup / rollback 子命令）
├── UPSTREAM_VERSION           # 当前已同步的官方稳定版 Tag
├── CHANGELOG-CLEAN.md         # GPL-3.0 合规修改记录与版本追踪
└── LICENSE                    # GNU General Public License v3.0
```

---

## 四、GPL-3.0 开源合规声明

本项目严格遵守 **GNU General Public License v3.0 (GPL-3.0)**：
- **上游原始项目**：[MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui)（版权归原作者 MHSanaei 及贡献者所有）。
- **修改内容声明**：每次构建均通过 [`patches/apply-clean.sh`](./patches/apply-clean.sh) 自动化应用，具体变更文件与日期记录于 [`CHANGELOG-CLEAN.md`](./CHANGELOG-CLEAN.md)。
- **完整对应源码（Corresponding Source）**：每个 GitHub Release 均随附打完补丁后的完整对应源码归档包 `3x-ui-clean-<tag>-source.tar.gz` 及其 SHA256 校验值。
