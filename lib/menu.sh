#!/usr/bin/env bash
set -eEuo pipefail

umask 077

# 本文件由 sb.sh 模块拆分生成：函数自原 sb.sh 原样迁出（见各自函数上方注释）。
# 依赖 lib/common.sh 提供的基础函数与全局变量，须在 common.sh 之后被 source。

menu_add_node() {
  echo
  echo "1. VLESS + Reality"
  echo "2. VLESS + WS + TLS"
  echo "3. AnyTLS"
  echo "4. VLESS + Argo"
  echo "5. TUIC v5"
  echo "6. Hysteria2"
  echo "7. SOCKS5"
  echo "0. 返回"
  echo
  read -r -p "请选择: " choice || return 0
  case "${choice}" in
  1) add_vless_reality ;;
  2) add_vless_ws_tls ;;
  3) add_anytls ;;
  4) add_vless_argo ;;
  5) add_tuic_v5 ;;
  6) add_hy2 ;;
  7) add_socks5 ;;
  0) return 0 ;;
  *) print_warn "无效的选择。" ;;
  esac
}

print_header() {
  clear 2>/dev/null || true
  echo "=============================================="
  echo "${PROJECT_NAME} ${SCRIPT_VERSION}"
  echo "=============================================="
  echo
}

ipver_display() {
  case "$(get_setting "ip_version" "4")" in
  6 | v6) printf 'v6' ;;
  auto) printf 'auto（v4 优先）' ;;
  *) printf 'v4（默认）' ;;
  esac
}

settings_menu() {
  local choice value
  while true; do
    print_header
    echo "全局设置"
    echo
    echo "1. 分享链接默认 IP 版本   当前：$(ipver_display)"
    echo "0. 返回"
    echo
    read -r -p "请选择: " choice || return 0
    case "${choice}" in
    1)
      read -r -p "IP 版本 (4/v6/auto) [4]: " value || continue
      value="$(normalize_input "${value:-4}")"
      case "${value,,}" in
      4 | v4) set_setting "ip_version" "4" ;;
      6 | v6) set_setting "ip_version" "6" ;;
      auto) set_setting "ip_version" "auto" ;;
      *) print_warn "无效的值：${value}（可选 4 / v6 / auto）" ;;
      esac
      ;;
    0) return 0 ;;
    *)
      print_warn "无效的选择。"
      sleep 1
      ;;
    esac
  done
}

pause_menu() {
  read -r -p "按回车继续..." _ || true
}

# net_tune 现值展示（BBR+FQ+缓存设置菜单）
net_tune_display_values() {
  local bw rtt region buf cap
  bw="$(get_setting "net_tune_bandwidth_mbps")"
  rtt="$(get_setting "net_tune_latency_ms")"
  region="$(get_setting "net_tune_region")"
  buf="$(get_setting "net_tune_buffer_mb")"
  cap="$(get_tcp_buffer_cap_mb)"
  printf '当前：带宽 %s Mbps | 延迟 %s ms | 档位 %s | TCP缓冲 %s MB（内存上限 %s MB）\n' \
    "$(hl_num "${bw:-未测}")" "$(hl_num "${rtt:-未测}")" "${region:-未设}" "$(hl_num "${buf:-未算}")" "$(hl_num "${cap}")"
}

# 手动重填带宽/延迟后：重算档位与缓冲、持久化、立即应用（BBR+FQ+缓存设置）
# 文件内依赖：infer_net_tune_region / calculate_net_tune_buffer_mb / apply_sysctls（lib/common.sh）
net_tune_apply_manual() {
  local bandwidth="$1" latency="$2" region cap_mb buffer_mb buffer_bytes
  region="$(infer_net_tune_region "${latency}")"
  cap_mb="$(get_tcp_buffer_cap_mb)"
  buffer_mb="$(calculate_net_tune_buffer_mb "${bandwidth}" "${region}")"
  set_setting "net_tune_bandwidth_mbps" "${bandwidth}"
  set_setting "net_tune_latency_ms" "${latency}"
  set_setting "net_tune_region" "${region}"
  set_setting "net_tune_buffer_mb" "${buffer_mb}"
  buffer_bytes=$((buffer_mb * 1024 * 1024))
  if [ "$(id -u 2>/dev/null || echo 1)" = "0" ] && command_exists sysctl; then
    apply_sysctls "${buffer_bytes}"
  fi
  print_ok "已应用：带宽 ${COLOR_NUM_HL}${bandwidth}${COLOR_RESET} Mbps，延迟 ${COLOR_NUM_HL}${latency}${COLOR_RESET} ms（${region} 档）→ TCP 缓冲 ${COLOR_NUM_HL}${buffer_mb}${COLOR_RESET}MB。"
}

net_tune_menu() {
  local choice bw rtt buf
  while true; do
    print_header
    echo "BBR+FQ+缓存设置"
    echo
    net_tune_display_values
    echo
    echo "1. 自动测速并确认（测速度+延迟，可人工复核）"
    echo "2. 手动重填带宽与延迟"
    echo "3. 查看当前生效 sysctl 网络参数"
    echo "0. 返回"
    echo
    read -r -p "请选择: " choice || return 0
    case "${choice}" in
    1)
      # 清空已持久化结果强制重新测速+确认（apply_network_tune 见持久化值则跳过）
      set_setting "net_tune_buffer_mb" ""
      set_setting "net_tune_bandwidth_mbps" ""
      set_setting "net_tune_latency_ms" ""
      apply_network_tune
      pause_menu
      ;;
    2)
      bw="$(prompt_positive_integer "带宽 (Mbps)" "1000")"
      rtt="$(prompt_with_default "延迟 (ms，留空自动推断档位)" "$(get_setting "net_tune_latency_ms")")"
      rtt="$(normalize_input "${rtt}")"
      if ! [[ "${rtt}" =~ ^[0-9]+$ ]]; then
        print_warn "延迟无效（${rtt:-空}），回退按 asia 档。"
        rtt=""
      fi
      net_tune_apply_manual "${bw}" "${rtt}"
      pause_menu
      ;;
    3)
      echo
      echo "------------------ net.core ------------------"
      sysctl net.core.rmem_max net.core.wmem_max net.core.default_qdisc 2>/dev/null || echo "(无)"
      echo "------------------ net.ipv4 ------------------"
      sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
        net.ipv4.tcp_limit_output_bytes net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo "(无)"
      echo
      pause_menu
      ;;
    0) return 0 ;;
    *)
      print_warn "无效的选择。"
      sleep 1
      ;;
    esac
  done
}

main_menu() {
  detect_systemd
  init_storage
  while true; do
    print_header
    echo "1. 安装/更新核心组件"
    echo "2. 添加节点"
    echo "3. 查看节点"
    echo "4. 删除节点"
    echo "5. 重启服务"
    echo "6. 查看状态"
    echo "7. 更新项目文件"
    echo "8. BBR+FQ+缓存设置"
    echo "9. 全局设置"
    echo "10. 卸载"
    echo "0. 退出"
    echo
    choice=""
    read -r -p "请选择: " choice || true
    if [ -z "${choice}" ] && [ ! -t 0 ]; then
      return 0
    fi
    case "${choice}" in
    1)
      install_core
      pause_menu
      ;;
    2)
      menu_add_node
      pause_menu
      ;;
    3)
      list_nodes
      pause_menu
      ;;
    4)
      delete_node
      pause_menu
      ;;
    5)
      restart_stack
      pause_menu
      ;;
    6)
      show_status
      pause_menu
      ;;
    7)
      update_script
      pause_menu
      ;;
    8)
      net_tune_menu
      ;;
    9)
      settings_menu
      ;;
    10)
      if uninstall_project; then
        exit 0
      fi
      pause_menu
      ;;
    0) exit 0 ;;
    *)
      print_warn "无效的选择。"
      sleep 1
      ;;
    esac
  done
}

print_cli_usage() {
  cat <<EOF
用法: sbm [命令]

命令:
  (无参数)   打开交互式主菜单
  rep        覆盖式一键安装：备份后清空已有节点，按环境变量重建并启动
  ins        追加式一键安装：备份后保留已有节点，按环境变量追加节点并启动
  list       查看节点与分享链接
  sub [文件] 输出 base64 订阅内容（不带文件参数打印到 stdout，带则写入文件）
  delall     删除全部节点（含证书）并重启服务
  restore    从最近一次状态备份恢复节点
  un         卸载本项目

环境变量一键安装示例（配合网页命令生成器使用）:
  vlrt=2083 hypt=2082 name='HK' bash sb.sh rep
  支持的环境变量见 README「环境变量一键安装」章节。

MTProxy（Go mtg）为独立脚本，不依赖本命令：
  mtpt=端口 bash <(curl -fsSL https://github.com/hynize/singbox-manager/releases/latest/download/install.sh)
  或已安装时直接: mtpt=端口 mtp
EOF
}
