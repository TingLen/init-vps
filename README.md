# init-vps

用于 Debian / Ubuntu 的个人 VPS 初始化脚本。

## 一键运行

通过 SSH 登录 VPS 后，以 root 执行（支持 Bash 和 Fish）：

```bash
curl -fsSL https://raw.githubusercontent.com/TingLen/init-vps/main/init-vps.sh | bash
```

脚本使用 Bash 执行，已内嵌 Ghostty 终端定义，无需额外文件。

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

- 安装基础工具、Helix、Docker、Fish，以及 bat、glow、zoxide。
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

## 日志

- 完整日志：`/var/log/init-vps/`。
- 最近一次成功摘要：`/var/lib/init-vps/summary.txt`。
- SSH 原配置备份：`/var/lib/init-vps/sshd_config.backup`。

```bash
cat /var/lib/init-vps/summary.txt
```

已通过 Bash 语法检查和 SSH 切换模拟验证，尚未在真实 VPS 完成联调。`main` 链接始终使用仓库最新版。
