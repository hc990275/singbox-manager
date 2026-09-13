#!/usr/bin/env bash
set -eEuo pipefail

###############################################################################
# MTProxy (Go mtg) 独立管理脚本 —— 与 Singbox Manager(sb.sh) 完全分离
#
# 命令:
#   mtp              安装/更新 MTProxy（环境变量 mtpt 指定端口，缺省则为首次安装）
#   mtp info         查看已安装服务连接信息（tg://proxy 链接）
#   mtp restart      重启 MTProxy 服务
#   mtp un           全量卸载并清理（服务、二进制、配置、日志）
#
# 环境变量:
#   mtpt          监听端口（必填，安装时启用）
#   mtp_domain    伪装域名（可选，默认从内置列表随机）
#   mtp_secret    通信密钥 32 位 hex（可选，默认随机生成）
#   mtp_ip_mode   监听模式 v4 / v6 / dual（可选，默认 v4）
###############################################################################

SCRIPT_VERSION="1.2.7"

# MTG GO 版本与校验：上游 jyucoeng/singbox-tools 的 Go 构建镜像
MTP_WORKDIR="/opt/mtproxy"
MTP_BIN_DIR="${MTP_WORKDIR}/bin"
MTP_CONF="${MTP_WORKDIR}/go.conf"
MTP_LOG="${MTP_WORKDIR}/mtp.log"
MTP_SERVICE="mtp"
MTP_DOWNLOAD_BASE="https://github.com/jyucoeng/singbox-tools/releases/download/Go-Rust"
# 参考实现内置伪装域名（上游生成器同款列表）
MTP_FAKE_DOMAINS=("www.apple.com" "www.microsoft.com" "www.amazon.com" "www.bing.com" "www.mozilla.org")

# 颜色输出（非 TTY 或 NO_COLOR 时禁用）
supports_color() {
  if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then return 1; fi
  return 0
}

GREEN=""; RED=""; YELLOW=""; BLUE=""; PLAIN=""
if supports_color; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; PLAIN=$'\033[0m'
fi

mtp_print_ok()   { echo -e "${GREEN}[OK] $*${PLAIN}"; }
mtp_print_info() { echo -e "${BLUE}[INFO] $*${PLAIN}"; }
mtp_print_warn() { echo -e "${YELLOW}[WARN] $*${PLAIN}"; }
mtp_print_err()  { echo -e "${RED}[ERROR] $*${PLAIN}" >&2; }

mtp_fatal() {
  mtp_print_err "$*"
  exit 1
}

is_num() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

valid_port() {
  local p="$1"
  is_num "$p" && [ "${p}" -ge 1 ] && [ "${p}" -le 65535 ]
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

download_file() {
  local url="$1" out="$2"
  if command_exists curl; then
    curl -fsSL --retry 3 --connect-timeout 10 "$url" -o "$out"
  elif command_exists wget; then
    wget -qO "$out" "$url"
  else
    mtp_fatal "需要安装 curl 或 wget 才能下载 MTProxy 二进制。"
  fi
}

# 检测 init 系统
detect_init_system() {
  if [ -d /run/systemd/system ]; then
    INIT_SYSTEM="systemd"
  elif [ -f /sbin/openrc-run ] || [ -f /etc/alpine-release ]; then
    INIT_SYSTEM="openrc"
  elif [ -f /etc/init.d/rcS ] && command -v service >/dev/null 2>&1; then
    INIT_SYSTEM="sysvinit"
  else
    INIT_SYSTEM="unknown"
  fi
}

# 获取本机公网 IPv4/IPv6（自包含实现，不依赖外部库）
get_public_ipv4() {
  local ip url
  for url in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.me"; do
    ip="$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d '\r\n' || true)"
    case "$ip" in
    *[!0-9.]*) continue ;;
    esac
    [ -z "$ip" ] && continue
    printf '%s' "$ip"
    return 0
  done
  return 1
}

get_public_ipv6() {
  local ip url
  for url in "https://api64.ipify.org" "https://v6.ipv6-test.com/api/myip.php" "https://ifconfig.co"; do
    ip="$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d '\r\n' || true)"
    case "$ip" in
    *:*)
      printf '%s' "$ip"
      return 0
      ;;
    *) continue ;;
    esac
  done
  return 1
}

# 生成 32 位 hex 密钥（16 字节）
generate_secret() {
  head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n'
}

random_domain() {
  # 用 date 纳秒对内置列表长度取模，纯 bash 无竞态
  local idx
  idx=$(( $(date +%s%N) % ${#MTP_FAKE_DOMAINS[@]} ))
  printf '%s' "${MTP_FAKE_DOMAINS[$idx]}"
}

env_port() {
  local raw="${1:-}"
  [ -n "${raw}" ] || return 1
  valid_port "${raw}" || return 1
  printf '%s' "${raw}"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    mtp_fatal "需要 root 权限，请使用 sudo 或以 root 身份运行。"
  fi
}

is_service_installed() {
  if [ "${INIT_SYSTEM}" = "systemd" ]; then
    [ -f "/etc/systemd/system/${MTP_SERVICE}.service" ]
  elif [ "${INIT_SYSTEM}" = "openrc" ]; then
    [ -f "/etc/init.d/${MTP_SERVICE}" ]
  else
    [ -f "${MTP_CONF}" ]
  fi
}

print_usage() {
  cat <<EOF
用法: mtp [命令]

命令:
  (无参数)    安装/更新 MTProxy。环境变量 mtpt 指定监听端口；mtp_domain/mtp_secret/mtp_ip_mode 可选。
  info        查看已安装服务连接信息（tg://proxy 链接）
  restart     重启 MTProxy 服务
  un          全量卸载并清理（服务、二进制、配置、日志）
  -h|--help   显示本帮助

环境变量:
  mtpt          监听端口（必填）
  mtp_domain    伪装域名（默认从内置列表随机）
  mtp_secret    通信密钥，32 位 hex（默认随机生成）
  mtp_ip_mode   监听模式 v4 / v6 / dual（默认 v4）
EOF
}

# 生成 tg:// 链接 secret（与上游 show_info_mtg 一致：
# FULL_SECRET = 0xee + secret(32hex 16字节) + domain 字节串，base64 url-safe 无 padding）
mtp_tg_secret() {
  local secret="$1" domain="$2"
  local raw secret_b64
  raw="$(echo -n "${secret}" | sed 's/../\\x&/g')"
  secret_b64="$(printf '\xee%b%b' "${raw}" "${domain}" | base64 | tr -d '\r\n' | tr '+/' '-_' | tr -d '=')"
  printf '%s' "${secret_b64}"
}

mtp_install_binary() {
  local arch mtg_arch bin_url bin_tmp
  arch="$(uname -m)"
  case "${arch}" in
  x86_64 | amd64) mtg_arch="amd64" ;;
  aarch64 | arm64) mtg_arch="arm64" ;;
  *)
    mtp_print_err "不支持的 CPU 架构：${arch}（仅支持 x86_64/aarch64）。"
    return 1
    ;;
  esac

  if [ -x "${MTP_BIN_DIR}/mtg-go" ] && "${MTP_BIN_DIR}/mtg-go" --version >/dev/null 2>&1; then
    mtp_print_info "已存在可用的 mtg-go 二进制，跳过下载。"
    return 0
  fi

  mkdir -p "${MTP_BIN_DIR}"
  bin_url="${MTP_DOWNLOAD_BASE}/mtg-go-${mtg_arch}"
  bin_tmp="${MTP_BIN_DIR}/.mtg-go.tmp"
  mtp_print_info "下载 mtg-go (${arch}) ..."
  if ! download_file "${bin_url}" "${bin_tmp}"; then
    rm -f "${bin_tmp}"
    mtp_print_err "下载失败：${bin_url}"
    return 1
  fi
  chmod 0755 "${bin_tmp}"
  if ! "${bin_tmp}" --version >/dev/null 2>&1; then
    rm -f "${bin_tmp}"
    mtp_print_err "下载的 mtg-go 二进制无法执行，已放弃（可能下载到损坏文件）。"
    return 1
  fi
  mv -f "${bin_tmp}" "${MTP_BIN_DIR}/mtg-go"
  chmod 0755 "${MTP_BIN_DIR}/mtg-go"
  mtp_print_ok "mtg-go 安装完成：${MTP_BIN_DIR}/mtg-go"
}

mtp_create_service() {
  local port="$1" secret="$2" domain="$3" ip_mode="$4"
  local hex_domain full_secret net_args cmd_line

  hex_domain="$(echo -n "${domain}" | od -A n -t x1 | tr -d ' \n')"
  full_secret="ee${secret}${hex_domain}"

  case "${ip_mode}" in
  v6) net_args="-i only-ipv6 [::]:${port}" ;;
  dual) net_args="-i prefer-ipv6 [::]:${port}" ;;
  *) net_args="-i only-ipv4 0.0.0.0:${port}" ;;
  esac

  cmd_line="${MTP_BIN_DIR}/mtg-go simple-run -n 1.1.1.1 -t 30s -a 1mb -c 65535 ${net_args} ${full_secret}"

  mkdir -p "${MTP_WORKDIR}"
  cat > "${MTP_CONF}" <<EOF
PORT=${port}
SECRET=${full_secret}
DOMAIN=${domain}
IP_MODE=${ip_mode}
EOF
  chmod 0600 "${MTP_CONF}"

  if [ "${INIT_SYSTEM}" = "systemd" ]; then
    cat > "/etc/systemd/system/${MTP_SERVICE}.service" <<EOF
[Unit]
Description=MTProto Proxy (Go - mtg)
After=network.target

[Service]
Type=simple
ExecStart=${cmd_line}
Restart=always
RestartSec=3
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${MTP_SERVICE}" >/dev/null 2>&1 || true
    systemctl restart "${MTP_SERVICE}"
  elif [ "${INIT_SYSTEM}" = "openrc" ]; then
    cat > "/etc/init.d/${MTP_SERVICE}" <<EOF
#!/sbin/openrc-run
name="${MTP_SERVICE}"
description="MTProto Proxy (Go)"
command="${MTP_BIN_DIR}/mtg-go"
command_args="simple-run -n 1.1.1.1 -t 30s -a 1mb -c 65535 ${net_args} ${full_secret}"
pidfile="/run/${MTP_SERVICE}.pid"
command_background="true"
rc_ulimit="-n 65535"

depend() {
    need net
}
EOF
    chmod +x "/etc/init.d/${MTP_SERVICE}"
    rc-update add "${MTP_SERVICE}" default >/dev/null 2>&1 || true
    rc-service "${MTP_SERVICE}" restart
  else
    # 无服务管理器：后台运行并写 pidfile（尽力而为）
    nohup sh -c "${cmd_line} >>${MTP_LOG} 2>&1" >/dev/null 2>&1 &
    echo $! > "${MTP_WORKDIR}/mtp.pid"
    mtp_print_warn "未检测到 systemd/openrc，已用 nohup 后台运行（pid: $(cat "${MTP_WORKDIR}/mtp.pid")）。"
  fi
}

mtp_show_info() {
  local port secret domain ip_mode ipv4 ipv6 tg_secret
  if [ ! -f "${MTP_CONF}" ]; then
    mtp_print_err "MTProxy 尚未安装（缺少 ${MTP_CONF}）。先运行：mtpt=端口 mtp"
    return 1
  fi
  # 从配置读取（配置中 SECRET 为完整 FULL_SECRET，第 3 位起的 32 位 hex 即原密钥）
  port="$(grep -m1 '^PORT=' "${MTP_CONF}" | cut -d= -f2)"
  secret="$(grep -m1 '^SECRET=' "${MTP_CONF}" | cut -d= -f2 | cut -c3-34)"
  domain="$(grep -m1 '^DOMAIN=' "${MTP_CONF}" | cut -d= -f2)"
  ip_mode="$(grep -m1 '^IP_MODE=' "${MTP_CONF}" | cut -d= -f2)"

  ipv4="$(get_public_ipv4 || true)"
  ipv6="$(get_public_ipv6 || true)"
  tg_secret="$(mtp_tg_secret "${secret}" "${domain}")"

  echo -e "=============================="
  echo -e "${GREEN}MTProxy (Go mtg) 连接信息${PLAIN}"
  echo -e "端口: ${port}"
  echo -e "Secret: ${tg_secret}"
  echo -e "Domain: ${domain}"
  echo -e "监听模式: ${ip_mode}"
  echo -e "------------------------------"
  if [ -n "${ipv4}" ]; then
    echo -e "${GREEN}IPv4 链接:${PLAIN}"
    echo "tg://proxy?server=${ipv4}&port=${port}&secret=${tg_secret}"
  else
    echo -e "${YELLOW}未检测到 IPv4 地址${PLAIN}"
  fi
  if [ "${ip_mode}" = "v6" ] || [ "${ip_mode}" = "dual" ]; then
    if [ -n "${ipv6}" ]; then
      echo -e "${GREEN}IPv6 链接:${PLAIN}"
      echo "tg://proxy?server=${ipv6}&port=${port}&secret=${tg_secret}"
    else
      echo -e "${YELLOW}未检测到 IPv6 地址${PLAIN}"
    fi
  fi
  echo -e "=============================="
}

mtp_status() {
  local active
  if [ ! -f "${MTP_CONF}" ]; then
    mtp_print_err "MTProxy 未安装。"
    return 1
  fi
  case "${INIT_SYSTEM}" in
  systemd)
    active="$(systemctl is-active "${MTP_SERVICE}" 2>/dev/null || echo inactive)"
    echo -e "服务: ${MTP_SERVICE} (systemd) ${GREEN}${active}${PLAIN}"
    ;;
  openrc)
    active="$(rc-service "${MTP_SERVICE}" status 2>/dev/null | grep -qi 'started' && echo started || echo stopped)"
    echo -e "服务: ${MTP_SERVICE} (openrc) ${GREEN}${active}${PLAIN}"
    ;;
  *)
    echo -e "服务: ${MTP_SERVICE} (无服务管理器)"
    ;;
  esac
}

# 安装/更新主流程
mtp_install() {
  local port domain secret ip_mode

  require_root
  detect_init_system

  port="$(env_port "${mtpt:-}")" || {
    mtp_print_err "缺少有效的监听端口：mtpt=端口（1-65535）"
    print_usage
    return 1
  }

  # 已有安装时保留已生成值，未显式指定的新安装使用随机值
  domain="${mtp_domain:-}"
  secret="${mtp_secret:-}"
  if [ -f "${MTP_CONF}" ] && [ -z "${domain}" ] && [ -z "${secret}" ]; then
    domain="$(grep -m1 '^DOMAIN=' "${MTP_CONF}" | cut -d= -f2 || true)"
    secret="$(grep -m1 '^SECRET=' "${MTP_CONF}" | cut -d= -f2 | cut -c3-34 || true)"
  fi
  [ -n "${domain}" ] || domain="$(random_domain)"
  [ -n "${secret}" ] || secret="$(generate_secret)"

  case "${mtp_ip_mode:-v4}" in
  v4 | v6 | dual) ip_mode="${mtp_ip_mode:-v4}" ;;
  *) mtp_print_err "mtp_ip_mode 仅支持 v4 / v6 / dual。"; return 1 ;;
  esac

  if [ -f "${MTP_CONF}" ]; then
    old_port="$(grep -m1 '^PORT=' "${MTP_CONF}" | cut -d= -f2 || true)"
    if [ -n "${old_port}" ] && [ "${port}" != "${old_port}" ]; then
      mtp_print_info "监听端口变更：${old_port} → ${port}"
    fi
  fi

  mtp_install_binary || return 1
  mtp_create_service "${port}" "${secret}" "${domain}" "${ip_mode}"
  mtp_status || true
  mtp_show_info
  mtp_print_ok "MTProxy 安装/更新完成。"
}

mtp_restart() {
  require_root
  detect_init_system
  if ! is_service_installed; then
    mtp_print_err "MTProxy 尚未安装。"
    return 1
  fi
  case "${INIT_SYSTEM}" in
  systemd)
    systemctl restart "${MTP_SERVICE}"
    mtp_print_ok "已重启 ${MTP_SERVICE}。"
    ;;
  openrc)
    rc-service "${MTP_SERVICE}" restart
    mtp_print_ok "已重启 ${MTP_SERVICE}。"
    ;;
  *)
    mtp_print_warn "无服务管理器，通过 pidfile 重启。"
    if [ -f "${MTP_WORKDIR}/mtp.pid" ]; then
      kill "$(cat "${MTP_WORKDIR}/mtp.pid")" >/dev/null 2>&1 || true
    fi
    nohup sh -c "${MTP_BIN_DIR}/mtg-go simple-run -n 1.1.1.1 -t 30s -a 1mb -c 65535 -i only-ipv4 0.0.0.0:$(grep -m1 '^PORT=' "${MTP_CONF}" | cut -d= -f2) $(grep -m1 '^SECRET=' "${MTP_CONF}" | cut -d= -f2) >>${MTP_LOG} 2>&1" >/dev/null 2>&1 &
    echo $! > "${MTP_WORKDIR}/mtp.pid"
    mtp_print_ok "已重启 ${MTP_SERVICE}（pid: $(cat "${MTP_WORKDIR}/mtp.pid")）。"
    ;;
  esac
}

mtp_uninstall() {
  require_root
  detect_init_system
  if ! is_service_installed && [ ! -d "${MTP_WORKDIR}" ]; then
    mtp_print_info "MTProxy 未安装，无需卸载。"
    return 0
  fi
  case "${INIT_SYSTEM}" in
  systemd)
    systemctl disable --now "${MTP_SERVICE}" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${MTP_SERVICE}.service"
    systemctl daemon-reload || true
    ;;
  openrc)
    rc-update del "${MTP_SERVICE}" default >/dev/null 2>&1 || true
    rc-service "${MTP_SERVICE}" stop >/dev/null 2>&1 || true
    rm -f "/etc/init.d/${MTP_SERVICE}"
    ;;
  *)
    if [ -f "${MTP_WORKDIR}/mtp.pid" ]; then
      kill "$(cat "${MTP_WORKDIR}/mtp.pid")" >/dev/null 2>&1 || true
    fi
    pkill -f "${MTP_BIN_DIR}/mtg-go" >/dev/null 2>&1 || true
    ;;
  esac
  rm -rf "${MTP_WORKDIR}"
  mtp_print_ok "MTProxy 已全量卸载并清理。"
}

main() {
  local action="${1:-}"
  case "${action}" in
  "")
    mtp_install
    ;;
  info)
    require_root
    detect_init_system
    mtp_show_info
    ;;
  restart)
    mtp_restart
    ;;
  un)
    mtp_uninstall
    ;;
  -h | --help | help)
    print_usage
    exit 0
    ;;
  *)
    mtp_print_warn "未知命令：${action}"
    print_usage
    exit 1
    ;;
  esac
}

if [ "${MTP_TEST_MODE:-0}" != "1" ]; then
  # 测试钩子：MTP_TEST_MODE=1 时供 tests/smoke.sh source 本文件做函数级验证
  main "$@"
fi