#!/usr/bin/env bash
# 运行期全局配置（PROJECT_NAME 及以下变量）由 lib/*.sh 各模块消费，
# 跨文件引用 shellcheck 不可见，文件级豁免 SC2034（unused）。
# shellcheck disable=SC2034
set -eEuo pipefail

umask 077

PROJECT_NAME="Singbox 管理器"
SCRIPT_VERSION="1.3.1"
REPO_OWNER="hynize"
REPO_NAME="singbox-manager"

INSTALL_BIN="${INSTALL_BIN:-/usr/local/bin/sbm}"
LIB_DIR="${LIB_DIR:-/usr/local/lib/singbox-manager}"
BASE_DIR="${BASE_DIR:-/usr/local/etc/singbox-manager}"
WATCHDOG_TARGET="${BASE_DIR}/watchdog.sh"
UPSTREAM_ENV="${LIB_DIR}/upstream.env"
PID_FILE="${BASE_DIR}/runtime/sing-box.pid"

SINGBOX_BIN="${SINGBOX_BIN:-/usr/local/bin/sing-box}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-/usr/local/bin/cloudflared}"
SERVICE_NAME="singbox-manager"
WATCHDOG_SERVICE_NAME="singbox-manager-watchdog"
WATCHDOG_TIMER_NAME="singbox-manager-watchdog.timer"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SYSTEMD_WATCHDOG_SERVICE_FILE="/etc/systemd/system/${WATCHDOG_SERVICE_NAME}.service"
SYSTEMD_WATCHDOG_TIMER_FILE="/etc/systemd/system/${WATCHDOG_TIMER_NAME}"
OPENRC_SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"

DEFAULT_CDN_DOMAIN="saas.sin.fan"
DEFAULT_REALITY_SERVER="www.apple.com"
DEFAULT_TLS_SERVER="www.apple.com"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT=""
if [ -f "${SCRIPT_DIR}/lib/common.sh" ]; then
  SOURCE_ROOT="${SCRIPT_DIR}"
  # shellcheck source=lib/common.sh
  . "${SCRIPT_DIR}/lib/common.sh"
elif [ -f "${LIB_DIR}/common.sh" ]; then
  # shellcheck source=/usr/local/lib/singbox-manager/common.sh
  . "${LIB_DIR}/common.sh"
else
  echo "未找到 common.sh。" >&2
  exit 1
fi

if [ -n "${SOURCE_ROOT}" ] && [ -f "${SOURCE_ROOT}/metadata/upstream.env" ]; then
  # shellcheck source=metadata/upstream.env
  . "${SOURCE_ROOT}/metadata/upstream.env"
elif [ -f "${UPSTREAM_ENV}" ]; then
  # shellcheck source=/usr/local/lib/singbox-manager/upstream.env
  . "${UPSTREAM_ENV}"
else
  fatal "未找到 upstream.env。"
fi

require_bash4
setup_common_traps

has_systemd=false
has_openrc=false

# 职责模块（lib/*.sh）：开发态先找 SCRIPT_DIR/lib，安装态回退 LIB_DIR
for _sbm_module in ui core nodes menu; do
  if [ -f "${SCRIPT_DIR}/lib/${_sbm_module}.sh" ]; then
    # shellcheck source=lib/${_sbm_module}.sh
    . "${SCRIPT_DIR}/lib/${_sbm_module}.sh"
  elif [ -f "${LIB_DIR}/${_sbm_module}.sh" ]; then
    # shellcheck source=lib/${_sbm_module}.sh
    . "${LIB_DIR}/${_sbm_module}.sh"
  else
    fatal "未找到 lib/${_sbm_module}.sh。"
  fi
done
unset _sbm_module
main() {
  local action="${1:-}"
  case "${action}" in
  "")
    require_root
    # 菜单内任何非零返回（如 stdin EOF）都以干净状态退出，不触发 ERR trap
    main_menu || exit 0
    ;;
  rep | ins)
    require_root
    auto_install "${action}"
    ;;
  list)
    require_root
    init_storage
    echo
    print_node_list
    echo
    ;;
  sub)
    require_root
    sub_command "${2:-}"
    ;;
  delall)
    require_root
    delete_all_nodes
    ;;
  restore)
    require_root
    init_storage
    acquire_lock
    if restore_latest_backup; then
      reconcile_state || true
      render_config
      start_service
      print_ok "已恢复并重启服务。"
    fi
    release_lock
    ;;
  un)
    require_root
    if uninstall_project; then
      exit 0
    fi
    exit 1
    ;;
  -h | --help | help)
    print_cli_usage
    ;;
  *)
    print_warn "未知命令：${action}"
    print_cli_usage
    exit 1
    ;;
  esac
}

if [ "${SBM_TEST_MODE:-0}" != "1" ]; then
  # 测试钩子：SBM_TEST_MODE=1 时供 tests/smoke.sh source 本文件做函数级验证
  main "$@"
fi
