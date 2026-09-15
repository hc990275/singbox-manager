#!/usr/bin/env bash
set -eEuo pipefail

umask 077

# 命令分发：由 sb.sh 在全部模块加载后调用 main "$@"
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
