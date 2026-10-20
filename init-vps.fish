#!/usr/bin/env bash
# Debian/Ubuntu VPS 初始化；建议先创建快照并确认控制台可用。
set -Eeuo pipefail
umask 022
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
SSH_PORT=${SSH_PORT:-22222}
TMP_DIR=''
SSH_PENDING=0
trap 'printf "[失败] 第 %s 行，退出码 %s；日志：%s\n" "$LINENO" "$?" "${LOG_FILE:-尚未创建}" >&2' ERR
cleanup() {
    local status=$?
    trap - EXIT
    if (( SSH_PENDING )); then
        printf '\n[恢复] SSH 切换未完成，正在恢复原配置和原端口放行规则。\n' >&2
        # 恢复过程中继续尝试全部步骤，同时保留原失败退出码。
        cp -a "$STATE/sshd_config.backup" /etc/ssh/sshd_config || printf '[恢复失败] 无法恢复主配置。\n' >&2
        rm -f "$SSH_CONFIG" || printf '[恢复失败] 无法删除新配置。\n' >&2
        while read -r old_port; do
            ufw allow "$old_port/tcp" || printf '[恢复失败] 无法放行旧端口 %s。\n' "$old_port" >&2
        done < "$STATE/old-ports"
        if ! /usr/sbin/sshd -t || ! systemctl reload ssh.service; then
            printf '[恢复失败] 请使用当前会话或厂商控制台检查 SSH。\n' >&2
        fi
    fi
    if [[ -n "$TMP_DIR" ]]; then rm -rf -- "$TMP_DIR" || true; fi
    exit "$status"
}
trap cleanup EXIT

fail() { printf '%s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail '请使用 root 执行。'
[[ $# -eq 0 ]] || fail '用法：bash init-vps.sh（无需第二阶段参数）'
[[ $SSH_PORT =~ ^[0-9]{4,5}$ ]] || fail 'SSH_PORT 必须是 1024–65535 的数字。'
SSH_PORT=$((10#$SSH_PORT))
(( SSH_PORT >= 1024 && SSH_PORT <= 65535 )) || fail 'SSH_PORT 必须在 1024–65535 之间。'
[[ -r /etc/os-release ]] || fail '无法识别系统。'
. /etc/os-release
[[ $ID == debian || $ID == ubuntu ]] || fail '目前仅支持 Debian/Ubuntu。'
[[ -d /run/systemd/system ]] || fail '需要正在运行的 systemd。'
command -v flock >/dev/null || fail '缺少 flock，请先安装 util-linux。'
exec 9>/run/init-vps.lock
flock -n 9 || fail '另一个初始化任务正在运行。'

SSH_CONFIG=/etc/ssh/sshd_config.d/00-init-vps.conf
STATE=/var/lib/init-vps
# root 直接运行时修改 root；sudo 运行时优先修改发起 sudo 的用户。
TARGET_USER=${TARGET_USER:-${SUDO_USER:-root}}
getent passwd "$TARGET_USER" >/dev/null || fail "用户不存在：$TARGET_USER"
install -d -m 700 /var/log/init-vps "$STATE"
LOG_FILE=$(mktemp "/var/log/init-vps/$(date +%Y%m%d-%H%M%S)-init.XXXXXX.log")
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
step() { printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n▶ %s\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n' "$*"; }
summary() {
    local phase=$1
    {
        printf '\n══════════ VPS 初始化摘要 ══════════\n'
        printf '时间：%s\n阶段：%s\n' "$(date -Is)" "$phase"
        printf 'SSH 新端口：%s/tcp\n' "$SSH_PORT"
        printf 'SSH 当前有效端口：\n'
        /usr/sbin/sshd -T | awk '$1 == "port" {print "  " $2 "/tcp"}'
        printf '默认 Shell：%s\n' "$(getent passwd "$TARGET_USER" | cut -d: -f1,7)"
        printf '终端：xterm-ghostty（由客户端传递 TERM）\n'
        printf '完整日志：%s\n摘要文件：%s/summary.txt\n' "$LOG_FILE" "$STATE"
        printf '防火墙：未默认开放 80/443；已有规则保留。\n'
        printf '提醒：检查云安全组；Docker 发布端口需单独验证。\n'
        ufw status verbose
    } | tee "$STATE/summary.txt"
    chmod 600 "$STATE/summary.txt"
}
step "VPS 初始化 · SSH $SSH_PORT · 用户 $TARGET_USER"
printf '日志文件：%s\n' "$LOG_FILE"

[[ ! -e $SSH_CONFIG ]] || fail '检测到已管理的 SSH 配置，本版拒绝重复初始化；可单独维护软件包。'
# socket 激活和复杂端口配置必须先人工梳理，避免生成表面成功的配置。
if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    fail '检测到 ssh.socket，请先明确切换为 ssh.service 管理后再运行。'
fi
[[ -x /usr/sbin/sshd ]] || fail '需要预先安装 openssh-server。'
systemctl is-active --quiet ssh.service || fail '需要正在运行的 ssh.service。'
/usr/sbin/sshd -t
# 本版只接管主配置中简单的 Port 指令，其他配置片段需要先人工整理。
if [[ -d /etc/ssh/sshd_config.d ]] && grep -rEq '^[[:space:]]*(Port|ListenAddress|Match)[[:space:]]' /etc/ssh/sshd_config.d; then
    fail 'SSH 配置片段含 Port、ListenAddress 或 Match，请先人工整理。'
fi
if grep -Eq '^[[:space:]]*(ListenAddress|Match)[[:space:]]' /etc/ssh/sshd_config; then
    fail '主 SSH 配置含 ListenAddress 或 Match，本版不自动接管。'
fi
if ss -H -ltn "sport = :$SSH_PORT" | grep -q .; then
    fail "目标端口 $SSH_PORT 已被监听，请选择空闲端口。"
fi

step "1/6 安装基础软件包"
apt-get -o DPkg::Lock::Timeout=120 update
apt-get -o DPkg::Lock::Timeout=120 install -y ca-certificates wget curl ufw nano less iproute2 lsof unzip git python3 fish tmux dnsutils jq xz-utils ncurses-bin ncurses-term
# 全量系统升级不默认执行，避免升级现有业务或触发配置文件交互。
TMP_DIR=$(mktemp -d)

step "2/6 安装 Helix"
# 优先使用发行版提供的 Helix，否则使用官方最新稳定发行版。
if apt-cache policy helix | grep -Eq 'Candidate: [^ (]'; then
    apt-get -o DPkg::Lock::Timeout=120 install -y helix
elif ! command -v hx >/dev/null; then
    case $(uname -m) in
        x86_64) helix_arch=x86_64 ;;
        aarch64|arm64) helix_arch=aarch64 ;;
        *) fail 'Helix 官方二进制安装仅支持 x86_64/aarch64。' ;;
    esac
    curl -fSL --retry 3 --connect-timeout 15 --max-time 120 \
        https://api.github.com/repos/helix-editor/helix/releases/latest -o "$TMP_DIR/helix.json"
    helix_url=$(jq -er --arg suffix "-$helix_arch-linux.tar.xz" \
        '[.assets[] | select(.name | endswith($suffix)) | .browser_download_url] | if length == 1 then .[0] else error("发行资产不唯一或不存在") end' "$TMP_DIR/helix.json")
    [[ $helix_url == https://github.com/helix-editor/helix/releases/download/* ]] || fail 'Helix 下载地址异常。'
    curl -fSL --retry 3 --connect-timeout 15 --max-time 600 "$helix_url" -o "$TMP_DIR/helix.tar.xz"
    mkdir "$TMP_DIR/helix"
    tar -xJf "$TMP_DIR/helix.tar.xz" -C "$TMP_DIR/helix" --strip-components=1
    [[ -x $TMP_DIR/helix/hx && -d $TMP_DIR/helix/runtime ]] || fail 'Helix 包结构异常。'
    [[ ! -e /opt/init-vps-helix && ! -e /usr/local/bin/hx ]] || fail 'Helix 安装路径已存在，拒绝覆盖。'
    cp -a "$TMP_DIR/helix" /opt/init-vps-helix
    cat > /usr/local/bin/hx <<'WRAPPER'
#!/bin/sh
export HELIX_RUNTIME=/opt/init-vps-helix/runtime
exec /opt/init-vps-helix/hx "$@"
WRAPPER
    chmod 755 /usr/local/bin/hx
fi
hx --version

step "3/6 安装并检查 Docker"
# 已有 Docker 时保留；首次安装使用官方便利脚本，下载成功后再执行。
if ! command -v docker >/dev/null; then
    curl -fSL --retry 3 --connect-timeout 15 --max-time 120 https://get.docker.com -o "$TMP_DIR/docker.sh"
    sh "$TMP_DIR/docker.sh"
fi
systemctl enable --now docker.service
docker info >/dev/null

step "4/6 配置 Fish 与 Ghostty"
fish_path=$(command -v fish)
[[ -x $fish_path ]] || fail 'Fish 安装失败。'
grep -Fxq "$fish_path" /etc/shells || printf '%s\n' "$fish_path" >> /etc/shells
previous_shell=$(getent passwd "$TARGET_USER" | cut -d: -f7)
printf '%s:%s\n' "$TARGET_USER" "$previous_shell" > "$STATE/previous-shell"
# 先完成终端能力安装，再切换默认 Shell；不覆盖 TERM 环境变量。
if ! infocmp -x xterm-ghostty >/dev/null 2>&1; then
    # 使用带引号的 heredoc 保留终端定义中的反斜杠和特殊字符。
    cat > "$TMP_DIR/ghostty.terminfo" <<'GHOSTTY_TERMINFO'
# 从本机官方 Ghostty 安装包导出的终端能力定义。
xterm-ghostty|ghostty|Ghostty terminal emulator,
	am, bce, ccc, hs, km, mc5i, mir, msgr, npc, xenl, AX, Su, Tc, XT, fullkbd,
	colors#256, cols#80, it#8, lines#24, pairs#32767,
	acsc=++\,\,--..00``aaffgghhiijjkkllmmnnooppqqrrssttuuvvwwxxyyzz{{||}}~~,
	bel=^G, blink=\E[5m, bold=\E[1m, cbt=\E[Z, civis=\E[?25l,
	clear=\E[H\E[2J, cnorm=\E[?12l\E[?25h, cr=^M,
	csr=\E[%i%p1%d;%p2%dr, cub=\E[%p1%dD, cub1=^H,
	cud=\E[%p1%dB, cud1=^J, cuf=\E[%p1%dC, cuf1=\E[C,
	cup=\E[%i%p1%d;%p2%dH, cuu=\E[%p1%dA, cuu1=\E[A,
	cvvis=\E[?12;25h, dch=\E[%p1%dP, dch1=\E[P, dim=\E[2m,
	dl=\E[%p1%dM, dl1=\E[M, dsl=\E]2;\007, ech=\E[%p1%dX,
	ed=\E[J, el=\E[K, el1=\E[1K, flash=\E[?5h$<100/>\E[?5l,
	fsl=^G, home=\E[H, hpa=\E[%i%p1%dG, ht=^I, hts=\EH,
	ich=\E[%p1%d@, ich1=\E[@, il=\E[%p1%dL, il1=\E[L, ind=^J,
	indn=\E[%p1%dS,
	initc=\E]4;%p1%d;rgb\:%p2%{255}%*%{1000}%/%2.2X/%p3%{255}%*%{1000}%/%2.2X/%p4%{255}%*%{1000}%/%2.2X\E\\,
	invis=\E[8m, kDC=\E[3;2~, kEND=\E[1;2F, kHOM=\E[1;2H,
	kIC=\E[2;2~, kLFT=\E[1;2D, kNXT=\E[6;2~, kPRV=\E[5;2~,
	kRIT=\E[1;2C, kbs=\177, kcbt=\E[Z, kcub1=\EOD, kcud1=\EOB,
	kcuf1=\EOC, kcuu1=\EOA, kdch1=\E[3~, kend=\EOF, kent=\EOM,
	kf1=\EOP, kf10=\E[21~, kf11=\E[23~, kf12=\E[24~,
	kf13=\E[1;2P, kf14=\E[1;2Q, kf15=\E[1;2R, kf16=\E[1;2S,
	kf17=\E[15;2~, kf18=\E[17;2~, kf19=\E[18;2~, kf2=\EOQ,
	kf20=\E[19;2~, kf21=\E[20;2~, kf22=\E[21;2~,
	kf23=\E[23;2~, kf24=\E[24;2~, kf25=\E[1;5P, kf26=\E[1;5Q,
	kf27=\E[1;5R, kf28=\E[1;5S, kf29=\E[15;5~, kf3=\EOR,
	kf30=\E[17;5~, kf31=\E[18;5~, kf32=\E[19;5~,
	kf33=\E[20;5~, kf34=\E[21;5~, kf35=\E[23;5~,
	kf36=\E[24;5~, kf37=\E[1;6P, kf38=\E[1;6Q, kf39=\E[1;6R,
	kf4=\EOS, kf40=\E[1;6S, kf41=\E[15;6~, kf42=\E[17;6~,
	kf43=\E[18;6~, kf44=\E[19;6~, kf45=\E[20;6~,
	kf46=\E[21;6~, kf47=\E[23;6~, kf48=\E[24;6~,
	kf49=\E[1;3P, kf5=\E[15~, kf50=\E[1;3Q, kf51=\E[1;3R,
	kf52=\E[1;3S, kf53=\E[15;3~, kf54=\E[17;3~,
	kf55=\E[18;3~, kf56=\E[19;3~, kf57=\E[20;3~,
	kf58=\E[21;3~, kf59=\E[23;3~, kf6=\E[17~, kf60=\E[24;3~,
	kf61=\E[1;4P, kf62=\E[1;4Q, kf63=\E[1;4R, kf7=\E[18~,
	kf8=\E[19~, kf9=\E[20~, khome=\EOH, kich1=\E[2~,
	kind=\E[1;2B, kmous=\E[<, knp=\E[6~, kpp=\E[5~,
	kri=\E[1;2A, oc=\E]104\007, op=\E[39;49m, rc=\E8,
	rep=%p1%c\E[%p2%{1}%-%db, rev=\E[7m, ri=\EM,
	rin=\E[%p1%dT, ritm=\E[23m, rmacs=\E(B, rmam=\E[?7l,
	rmcup=\E[?1049l, rmir=\E[4l, rmkx=\E[?1l\E>, rmso=\E[27m,
	rmul=\E[24m, rs1=\E]\E\\\Ec, sc=\E7,
	setab=\E[%?%p1%{8}%<%t4%p1%d%e%p1%{16}%<%t10%p1%{8}%-%d%e48;5;%p1%d%;m,
	setaf=\E[%?%p1%{8}%<%t3%p1%d%e%p1%{16}%<%t9%p1%{8}%-%d%e38;5;%p1%d%;m,
	sgr=%?%p9%t\E(0%e\E(B%;\E[0%?%p6%t;1%;%?%p5%t;2%;%?%p2%t;4%;%?%p1%p3%|%t;7%;%?%p4%t;5%;%?%p7%t;8%;m,
	sgr0=\E(B\E[m, sitm=\E[3m, smacs=\E(0, smam=\E[?7h,
	smcup=\E[?1049h, smir=\E[4h, smkx=\E[?1h\E=, smso=\E[7m,
	smul=\E[4m, tbc=\E[3g, tsl=\E]2;, u6=\E[%i%d;%dR, u7=\E[6n,
	u8=\E[?%[;0123456789]c, u9=\E[c, vpa=\E[%i%p1%dd,
	BD=\E[?2004l, BE=\E[?2004h, Clmg=\E[s,
	Cmg=\E[%i%p1%d;%p2%ds, Dsmg=\E[?69l, E3=\E[3J,
	Enmg=\E[?69h, Ms=\E]52;%p1%s;%p2%s\007, PE=\E[201~,
	PS=\E[200~, RV=\E[>c, Se=\E[2 q,
	Setulc=\E[58\:2\:\:%p1%{65536}%/%d\:%p1%{256}%/%{255}%&%d\:%p1%{255}%&%d%;m,
	Smulx=\E[4\:%p1%dm, Ss=\E[%p1%d q,
	Sync=\E[?2026%?%p1%{1}%-%tl%eh%;,
	XM=\E[?1006;1000%?%p1%{1}%=%th%el%;, XR=\E[>0q,
	fd=\E[?1004l, fe=\E[?1004h, kDC3=\E[3;3~, kDC4=\E[3;4~,
	kDC5=\E[3;5~, kDC6=\E[3;6~, kDC7=\E[3;7~, kDN=\E[1;2B,
	kDN3=\E[1;3B, kDN4=\E[1;4B, kDN5=\E[1;5B, kDN6=\E[1;6B,
	kDN7=\E[1;7B, kEND3=\E[1;3F, kEND4=\E[1;4F,
	kEND5=\E[1;5F, kEND6=\E[1;6F, kEND7=\E[1;7F,
	kHOM3=\E[1;3H, kHOM4=\E[1;4H, kHOM5=\E[1;5H,
	kHOM6=\E[1;6H, kHOM7=\E[1;7H, kIC3=\E[2;3~, kIC4=\E[2;4~,
	kIC5=\E[2;5~, kIC6=\E[2;6~, kIC7=\E[2;7~, kLFT3=\E[1;3D,
	kLFT4=\E[1;4D, kLFT5=\E[1;5D, kLFT6=\E[1;6D,
	kLFT7=\E[1;7D, kNXT3=\E[6;3~, kNXT4=\E[6;4~,
	kNXT5=\E[6;5~, kNXT6=\E[6;6~, kNXT7=\E[6;7~,
	kPRV3=\E[5;3~, kPRV4=\E[5;4~, kPRV5=\E[5;5~,
	kPRV6=\E[5;6~, kPRV7=\E[5;7~, kRIT3=\E[1;3C,
	kRIT4=\E[1;4C, kRIT5=\E[1;5C, kRIT6=\E[1;6C,
	kRIT7=\E[1;7C, kUP=\E[1;2A, kUP3=\E[1;3A, kUP4=\E[1;4A,
	kUP5=\E[1;5A, kUP6=\E[1;6A, kUP7=\E[1;7A, kxIN=\E[I,
	kxOUT=\E[O, rmxx=\E[29m, rv=\E\\[[0-9]+;[0-9]+;[0-9]+c,
	setrgbb=\E[48\:2\:%p1%d\:%p2%d\:%p3%dm,
	setrgbf=\E[38\:2\:%p1%d\:%p2%d\:%p3%dm, smxx=\E[9m,
	xm=\E[<%i%p3%d;%p1%d;%p2%d;%?%p4%tM%em%;,
	xr=\EP>\\|[ -~]+a\E\\,
GHOSTTY_TERMINFO
    tic -x -o /usr/share/terminfo "$TMP_DIR/ghostty.terminfo"
fi
infocmp -x xterm-ghostty >/dev/null
usermod --shell "$fish_path" "$TARGET_USER"
[[ $(getent passwd "$TARGET_USER" | cut -d: -f7) == "$fish_path" ]] || fail '默认 Shell 修改失败。'
printf '已将 %s 默认 Shell 改为 %s，重新登录生效。\n' "$TARGET_USER" "$fish_path"
fish --version

step "5/6 配置防火墙并切换 SSH 端口"
install -d -m 755 /etc/ssh/sshd_config.d
cp -a /etc/ssh/sshd_config "$STATE/sshd_config.backup"
/usr/sbin/sshd -T | awk '$1 == "port" {print $2}' | sort -nu > "$STATE/old-ports"
[[ -s $STATE/old-ports ]] || fail '未检测到原 SSH 端口。'
SSH_PENDING=1
# 先确保新旧管理端口可通行，再修改 SSH；失败时恢复旧端口规则。
sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp" comment 'SSH'
while read -r old_port; do ufw allow "$old_port/tcp" comment 'SSH rollback'; done < "$STATE/old-ports"
ufw logging low
ufw --force enable

# 只监听新端口，reload 保留通常情况下已经建立的 SSH 会话。
sed -i '/^[[:space:]]*Port[[:space:]]/d' /etc/ssh/sshd_config
sed -i '1i Include /etc/ssh/sshd_config.d/00-init-vps.conf' /etc/ssh/sshd_config
printf 'Port %s\n' "$SSH_PORT" > "$SSH_CONFIG"
/usr/sbin/sshd -t
actual_ports=$(/usr/sbin/sshd -T | awk '$1 == "port" {print $2}' | sort -nu)
[[ $actual_ports == "$SSH_PORT" ]] || fail '有效 SSH 配置含其他端口，停止切换。'
systemctl reload ssh.service

step "6/6 检查监听状态并关闭旧端口规则"
# reload 后给守护进程少量时间完成监听切换。
ssh_ready=0
for attempt in {1..10}; do
    if [[ -n $(ss -H -ltn "sport = :$SSH_PORT") ]]; then
        old_listener=0
        while read -r old_port; do
            if [[ $old_port != "$SSH_PORT" && -n $(ss -H -ltn "sport = :$old_port") ]]; then
                old_listener=1
            fi
        done < "$STATE/old-ports"
        if (( old_listener == 0 )); then ssh_ready=1; break; fi
    fi
    sleep 1
done
(( ssh_ready )) || fail 'SSH 监听检查失败，恢复原配置。'
systemctl is-active --quiet ssh.service
while read -r old_port; do
    [[ $old_port == "$SSH_PORT" ]] && continue
    ufw --force delete allow "$old_port/tcp"
done < "$STATE/old-ports"
SSH_PENDING=0
summary "初始化完成；SSH 已切换至新端口"
printf '\n初始化完成，无需再次运行脚本。下次连接使用：\n'
printf 'ssh -p %s 用户名@服务器地址\n' "$SSH_PORT"
printf 'Fish 在下次登录时生效。当前 SSH 会话请保留至新端口可用。\n'
printf '请检查云安全组；已有 OpenSSH 或宽泛 UFW 规则需人工核对。\n'
