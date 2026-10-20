# init-vps

用于 Debian / Ubuntu 的个人 VPS 初始化脚本。

## 一键运行

通过 SSH 登录 VPS 后，以 root 执行（支持 Bash 和 Fish）：

```bash
curl -fsSL https://raw.githubusercontent.com/TingLen/init-vps/main/init-vps.sh | bash
```

脚本使用 Bash 执行，已内嵌 Ghostty 终端定义、Helix 主题及 Starship 配置，无需额外配置文件。

若系统尚未安装 curl：

```bash
apt-get update && apt-get install -y ca-certificates curl
```

也可以先下载查看，再执行：

```bash
curl -fsSL https://raw.githubusercontent.com/TingLen/init-vps/main/init-vps.sh -o init-vps.sh
less init-vps.sh
bash init-vps.sh
```

## 执行前准备

- 提前在云安全组 / 厂商防火墙放行 **22222/tcp**。脚本会将 SSH 端口改为 22222，无需第二次执行。
- 建议创建快照，确认厂商控制台可用，并保留当前 SSH 会话至新端口连接可用。
- 需要 apt、systemd 和正在运行的 ssh.service；检测到 ssh.socket 或复杂 SSH 配置时会停止。

## 主要配置

- 安装基础工具、Helix、Docker、Fish、Starship，以及 bat、glow、zoxide。
- Helix 使用自定义 `iterm2_solarized_light` 浅色主题并启用真彩色，避免 SSH 下行号颜色对比不足。
- Starship 使用 Catppuccin Mocha 彩色分段提示符，SSH 下显示用户名与主机名，并关闭桌面通知。已有 Starship 时复用；否则下载官方最新稳定版（x86_64/aarch64），校验发布 SHA256 摘要后安装。
- 图标和分隔符需要客户端终端使用 Nerd Font；字体和终端背景仍由本机控制。
- `bat` 用于高亮查看文件（自动兼容 Debian 的 `batcat`）；`glow` 用于终端阅读 Markdown。
- Fish 自动初始化 zoxide，重新登录后可使用 `z 目录名` 跳转；这里的 `z` 指 zoxide 提供的命令。
- Glow 优先从系统源安装，无包时下载官方稳定版 deb（支持 amd64/arm64）。
- 将目标用户默认登录 Shell 设为 Fish，下次登录生效。
- 内嵌 xterm-ghostty 定义，缺少时自动安装。
- UFW 默认拒绝入站、允许出站，不默认开放 80/443，保留已有规则。Docker 发布端口需单独核查。
- SSH 配置或监听检查失败时，尝试恢复原配置和旧端口放行规则。

安装后连接：

```bash
ssh -p 22222 用户名@服务器地址
```

## 用户样式配置

配置写入 `TARGET_USER` 的家目录（root 运行时默认 root；sudo 运行时默认发起用户，也可通过环境变量指定），并设置为该用户所有：

- `~/.config/helix/config.toml`
- `~/.config/helix/themes/iterm2_solarized_light.toml`
- `~/.config/starship.toml`
- `~/.config/fish/conf.d/starship.fish`

已有同名文件会备份至 `/var/lib/init-vps/config-backups/`，然后写入上述配置；不覆盖 `config.fish` 或 `fish_variables`，不迁移 macOS 路径和开发工具环境。如果已有其他提示符初始化，需要自行移除重复初始化。Fish 样式在重新登录后生效，Helix 在重新打开后生效。

完整脚本包含 SSH 和防火墙初始化，且拒绝重复初始化；已初始化的 VPS 不应为更新样式重新运行完整脚本。当前 VPS 的两套样式已单独配置完成。

## 日志

- 完整日志：`/var/log/init-vps/`。
- 最近一次成功摘要：`/var/lib/init-vps/summary.txt`。
- SSH 原配置备份：`/var/lib/init-vps/sshd_config.backup`。

```bash
cat /var/lib/init-vps/summary.txt
```

样式变更可运行 `bash -n init-vps.sh` 和 `python3 tests/test_styles.py` 验证（需要 Python 3.11+、Bash 和 Fish；安装 Starship 时还会验证提示符渲染）。测试只在临时目录安装配置，不执行 SSH 或防火墙流程。

已通过 Bash 语法检查、样式配置隔离验证和原有 SSH 切换模拟验证，尚未在真实 VPS 完成联调。`main` 链接始终使用仓库最新版。
