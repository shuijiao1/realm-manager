#!/usr/bin/env bash
# Realm Manager for ShuiJiao
# Repo: https://github.com/shuijiao1/Realm-Manager

set -Eeuo pipefail

VERSION="0.1.3"
REPO_RAW="https://raw.githubusercontent.com/shuijiao1/Realm-Manager/main"
UPDATE_URL="$REPO_RAW/realm.sh"
VERSION_URL="$REPO_RAW/version.txt"

REALM_DIR="/root/realm"
REALM_BIN="$REALM_DIR/realm"
CONFIG_FILE="$REALM_DIR/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"
LOG_FILE="/var/log/realm-manager.log"
CRON_FILE="/etc/cron.d/realm-manager"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;35m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

say() { printf '%b\n' "$*"; }
info() { say "${BLUE}▶${NC} $*"; }
ok() { say "${GREEN}✓${NC} $*"; }
warn() { say "${YELLOW}⚠${NC} $*"; }
err() { say "${RED}✖${NC} $*" >&2; }
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true; }

need_root() {
	if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
		err "请使用 root 权限运行：sudo bash realm.sh"
		exit 1
	fi
}

have() { command -v "$1" >/dev/null 2>&1; }

install_pkg() {
	local pkgs=("$@")
	if have apt-get; then
		apt-get update
		DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
	elif have dnf; then
		dnf install -y "${pkgs[@]}"
	elif have yum; then
		yum install -y "${pkgs[@]}"
	else
		err "未找到 apt/dnf/yum，请手动安装：${pkgs[*]}"
		exit 1
	fi
}

ensure_deps() {
	local missing=()
	for c in curl tar grep sed awk systemctl; do
		have "$c" || missing+=("$c")
	done
	if ((${#missing[@]})); then
		info "安装依赖：${missing[*]}"
		install_pkg curl tar grep sed gawk systemd
	fi
	mkdir -p "$REALM_DIR"
	touch "$LOG_FILE" || true
}
arch_asset() {
	local arch
	arch="$(uname -m)"
	case "$arch" in
	x86_64 | amd64) echo "realm-x86_64-unknown-linux-gnu.tar.gz" ;;
	*)
		err "暂只支持 amd64/x86_64，当前架构：$arch"
		exit 1
		;;
	esac
}

latest_realm_version() {
	local tag
	tag="$(curl -fsSL https://api.github.com/repos/zhboner/realm/releases/latest | grep -m1 '"tag_name"' | sed -E 's/.*"v?([0-9.]+)".*/\1/' || true)"
	if [[ ! "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		tag="2.7.0"
		warn "获取最新版失败，使用备用版本 v$tag"
	fi
	echo "$tag"
}

write_default_config() {
	if [[ ! -s "$CONFIG_FILE" ]]; then
		cat >"$CONFIG_FILE" <<'CFG'
[network]
no_tcp = false
use_udp = true
ipv6_only = false
CFG
	fi
}

write_service() {
	cat >"$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Realm Port Forwarding Service
Documentation=https://github.com/zhboner/realm
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$REALM_BIN -c $CONFIG_FILE
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_SERVICE
	systemctl daemon-reload
}

install_realm() {
	ensure_deps
	local ver asset url tmp
	ver="$(latest_realm_version)"
	asset="$(arch_asset)"
	url="https://github.com/zhboner/realm/releases/download/v${ver}/${asset}"
	tmp="$(mktemp -d)"

	info "下载 Realm v$ver ($asset)"
	curl -fL --retry 3 -o "$tmp/realm.tar.gz" "$url"
	tar -xzf "$tmp/realm.tar.gz" -C "$tmp"
	install -m 0755 "$tmp/realm" "$REALM_BIN"
	rm -rf "$tmp"

	write_default_config
	write_service
	systemctl enable --now realm.service
	log "installed realm v$ver"
	ok "Realm 已安装/更新并启动"
}

validate_port() {
	[[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

valid_addr_port() {
	[[ "$1" =~ ^(.+):([0-9]+)$ ]] || return 1
	validate_port "${BASH_REMATCH[2]}"
}

escape_comment() {
	printf '%s' "$1" | tr '\n\r' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

next_id() {
	local max
	max="$(grep -E '^# id: [0-9]+' "$CONFIG_FILE" 2>/dev/null | awk '{print $3}' | sort -n | tail -1)"
	echo "$((${max:-0} + 1))"
}

restart_if_installed() {
	if systemctl list-unit-files realm.service >/dev/null 2>&1; then
		systemctl restart realm.service
	fi
}

add_rule() {
	write_default_config
	local listen_port remote_host remote_port listen_addr remark id
	read -rp "本地监听端口: " listen_port
	validate_port "$listen_port" || {
		err "端口无效"
		return 1
	}
	read -rp "目标地址/IP: " remote_host
	[[ -n "$remote_host" ]] || {
		err "目标地址不能为空"
		return 1
	}
	read -rp "目标端口: " remote_port
	validate_port "$remote_port" || {
		err "目标端口无效"
		return 1
	}

	say ""
	say "1) 双栈监听 [::]:$listen_port（默认）"
	say "2) IPv4 监听 0.0.0.0:$listen_port"
	say "3) 仅本机 127.0.0.1:$listen_port"
	say "4) 自定义完整监听地址"
	read -rp "请选择 [1-4] 默认1: " choice
	case "${choice:-1}" in
	1) listen_addr="[::]:$listen_port" ;;
	2) listen_addr="0.0.0.0:$listen_port" ;;
	3) listen_addr="127.0.0.1:$listen_port" ;;
	4)
		read -rp "监听地址（例 0.0.0.0:443 或 [::]:443）: " listen_addr
		valid_addr_port "$listen_addr" || {
			err "监听地址格式无效"
			return 1
		}
		;;
	*)
		err "选项无效"
		return 1
		;;
	esac
	read -rp "备注（可空）: " remark
	remark="$(escape_comment "$remark")"
	id="$(next_id)"

	cat >>"$CONFIG_FILE" <<EOF_RULE

[[endpoints]]
# id: $id
# 备注: $remark
listen = "$listen_addr"
remote = "$remote_host:$remote_port"
EOF_RULE
	restart_if_installed
	log "add rule id=$id $listen_addr -> $remote_host:$remote_port"
	ok "已添加规则 #$id：$listen_addr → $remote_host:$remote_port"
}

list_rules() {
	write_default_config
	printf '%b\n' "${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
	printf "%-6s | %-26s | %-34s | %s\n" "ID" "本地监听" "目标地址" "备注"
	printf '%b\n' "${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
	awk '
    BEGIN { id=""; remark=""; listen=""; remote=""; found=0; auto_id=0 }
    /^\[\[endpoints\]\]/ { if (listen || remote) print_rule(); found=1; id=""; remark=""; listen=""; remote=""; auto_id++; next }
    /^# id:/ { id=$3; next }
    /^# remark:/ { sub(/^# remark:[ ]*/, ""); remark=$0; next }
    /^# 备注:/ { sub(/^# 备注:[ ]*/, ""); remark=$0; next }
    /^#/ && remark == "" { sub(/^#[ ]*/, ""); remark=$0; next }
    /^listen[ ]*=/ { listen=$0; sub(/^[^\"]*\"/, "", listen); sub(/\".*/, "", listen); next }
    /^remote[ ]*=/ { remote=$0; sub(/^[^\"]*\"/, "", remote); sub(/\".*/, "", remote); next }
    function print_rule() { printf "%-6s | %-26s | %-34s | %s\n", (id?id:auto_id), listen, remote, remark }
    END { if (listen || remote) print_rule(); if (!found) print "暂无转发规则" }
  ' "$CONFIG_FILE"
	printf '%b\n' "${BLUE}---------------------------------------------------------------------------------------------------------${NC}"
}
delete_rule() {
	write_default_config
	say "当前规则："
	list_rules
	local id tmp
	read -rp "输入要删除的规则 ID（回车取消）: " id
	[[ -n "$id" ]] || return 0
	[[ "$id" =~ ^[0-9]+$ ]] || {
		err "ID 无效"
		return 1
	}

	tmp="$(mktemp)"
	awk -v target="$id" '
    BEGIN { inblk=0; drop=0; buf=""; matched=0 }
    /^\[\[endpoints\]\]/ { flush(); inblk=1; drop=0; buf=$0 ORS; next }
    inblk && /^# id:/ {
      split($0, a, " "); if (a[3] == target) { drop=1; matched=1 }
      buf = buf $0 ORS; next
    }
    inblk { buf = buf $0 ORS; next }
    { print }
    function flush() { if (inblk && !drop) printf "%s", buf; inblk=0; drop=0; buf="" }
    END { flush(); if (!matched) exit 42 }
  ' "$CONFIG_FILE" >"$tmp" || {
		local code=$?
		rm -f "$tmp"
		if [[ $code -eq 42 ]]; then err "未找到规则 ID：$id"; else err "删除失败"; fi
		return 1
	}
	install -m 0644 "$tmp" "$CONFIG_FILE"
	rm -f "$tmp"
	restart_if_installed
	log "delete rule id=$id"
	ok "已删除规则 #$id"
}

service_ctl() {
	case "$1" in
	start)
		systemctl enable --now realm.service
		ok "服务已启动"
		;;
	stop)
		systemctl stop realm.service
		ok "服务已停止"
		;;
	restart)
		systemctl restart realm.service
		ok "服务已重启"
		;;
	status) systemctl --no-pager --full status realm.service || true ;;
	esac
}

manage_cron() {
	say "1) 设置每日重启 Realm"
	say "2) 删除每日重启任务"
	say "3) 查看当前任务"
	read -rp "请选择: " c
	case "$c" in
	1)
		read -rp "每天几点重启（0-23）: " h
		[[ "$h" =~ ^[0-9]+$ ]] && ((h >= 0 && h <= 23)) || {
			err "小时无效"
			return 1
		}
		printf 'SHELL=/bin/sh\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n0 %s * * * root systemctl restart realm.service\n' "$h" >"$CRON_FILE"
		ok "已设置每日 ${h}:00 重启"
		;;
	2)
		rm -f "$CRON_FILE"
		ok "已删除 Realm 定时重启任务"
		;;
	3) [[ -f "$CRON_FILE" ]] && cat "$CRON_FILE" || say "暂无任务" ;;
	*) err "选项无效" ;;
	esac
}

uninstall_realm() {
	read -rp "确认卸载 Realm 并删除 $REALM_DIR ? 输入 yes: " yes
	[[ "$yes" == "yes" ]] || {
		warn "已取消"
		return 0
	}
	systemctl disable --now realm.service 2>/dev/null || true
	rm -f "$SERVICE_FILE" "$CRON_FILE"
	rm -rf "$REALM_DIR"
	systemctl daemon-reload
	log "uninstalled"
	ok "已卸载"
}

check_update() {
	local remote tmp
	remote="$(curl -fsSL "$VERSION_URL" 2>/dev/null | head -n1 | tr -cd '0-9.' || true)"
	[[ -n "$remote" && "$remote" != "$VERSION" ]] || {
		ok "脚本已是最新版本 v$VERSION"
		return 0
	}
	warn "发现脚本版本：本地 v$VERSION，远程 v$remote"
	read -rp "是否更新脚本本体？[y/N]: " yn
	[[ "$yn" =~ ^[Yy]$ ]] || return 0
	tmp="$(mktemp)"
	curl -fsSL "$UPDATE_URL" -o "$tmp"
	bash -n "$tmp"
	install -m 0755 "$tmp" "$0"
	rm -f "$tmp"
	ok "脚本已更新，请重新运行"
	exit 0
}

install_status() {
	if [[ -x "$REALM_BIN" && -f "$SERVICE_FILE" ]]; then printf "${GREEN}已安装${NC}"; else printf "${RED}未安装${NC}"; fi
}

run_status() {
	if systemctl is-active --quiet realm.service 2>/dev/null; then printf "${GREEN}运行中${NC}"; else printf "${RED}未运行${NC}"; fi
}

menu() {
	need_root
	ensure_deps
	while true; do
		clear || true
		say "${CYAN}============================================${NC}"
		say "          ${CYAN}Realm 转发管理脚本 v$VERSION${NC}"
		say "${CYAN}============================================${NC}"
		say "${GREEN}仓库: github.com/shuijiao1/Realm-Manager${NC}"
		say "${GREEN}作者: shuijiao1${NC}"
		say "${CYAN}============================================${NC}"
		say "安装状态：$(install_status)"
		say "运行状态：$(run_status)"
		say "配置文件：${CYAN}$CONFIG_FILE${NC}"
		say ""
		say "${BLUE}=== 基础功能 ===${NC}"
		say "${GREEN}1.${NC} 安装/更新 Realm"
		say "${GREEN}2.${NC} 卸载 Realm"
		say "${GREEN}3.${NC} 添加转发规则"
		say "${GREEN}4.${NC} 查看转发规则"
		say "${GREEN}5.${NC} 删除转发规则"
		say ""
		say "${BLUE}=== 服务管理 ===${NC}"
		say "${GREEN}6.${NC} 启动服务"
		say "${GREEN}7.${NC} 停止服务"
		say "${GREEN}8.${NC} 重启服务"
		say "${GREEN}9.${NC} 查看服务状态"
		say ""
		say "${BLUE}=== 系统功能 ===${NC}"
		say "${GREEN}10.${NC} 定时重启管理"
		say "${GREEN}11.${NC} 检查脚本更新"
		say "${GREEN}0.${NC} 退出脚本"
		say "${CYAN}============================================${NC}"
		read -rp "请输入选项 [0-11]: " choice
		case "$choice" in
		1) install_realm ;;
		2) uninstall_realm ;;
		3) add_rule ;;
		4) list_rules ;;
		5) delete_rule ;;
		6) service_ctl start ;;
		7) service_ctl stop ;;
		8) service_ctl restart ;;
		9) service_ctl status ;;
		10) manage_cron ;;
		11) check_update ;;
		0) exit 0 ;;
		*) err "无效选项" ;;
		esac
		say ""
		read -rp "按回车继续..." _
	done
}

case "${1:-}" in
install)
	need_root
	ensure_deps
	install_realm
	;;
add)
	need_root
	ensure_deps
	add_rule
	;;
list)
	need_root
	ensure_deps
	list_rules
	;;
delete)
	need_root
	ensure_deps
	delete_rule
	;;
start | stop | restart | status)
	need_root
	ensure_deps
	service_ctl "$1"
	;;
update-script)
	need_root
	ensure_deps
	check_update
	;;
-h | --help | help)
	cat <<HELP
用法：bash realm.sh [命令]
无命令：打开交互菜单
命令：install | add | list | delete | start | stop | restart | status | update-script
HELP
	;;
*) menu ;;
esac
