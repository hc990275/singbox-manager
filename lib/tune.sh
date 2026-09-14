#!/usr/bin/env bash
set -eEuo pipefail

umask 077

go_gc_requested() {
  [ "$(manager_env_or_setting "go_gc")" = "off" ] && return 0
  return 1
}

net_tune_requested() {
  case "$(manager_env_or_setting "net_tune")" in
  0 | off | no) return 1 ;;
  *) return 0 ;;
  esac
}

get_tcp_buffer_cap_mb() {
  local mem_kb
  mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)"
  if ! [[ "${mem_kb}" =~ ^[0-9]+$ ]]; then
    printf '%s' 64
  elif ((mem_kb < 524288)); then
    printf '%s' 16
  elif ((mem_kb < 1048576)); then
    printf '%s' 32
  else
    printf '%s' 64
  fi
}

calculate_net_tune_buffer_mb() {
  local bandwidth="$1" region="$2" cap_mb
  cap_mb="$(get_tcp_buffer_cap_mb)"
  local buffer_mb=16
  bandwidth="${bandwidth%.*}"
  if ! [[ "${bandwidth}" =~ ^[0-9]+$ ]] || ((bandwidth <= 0)); then
    bandwidth=1000
  fi
  if [ "${region}" = "overseas" ]; then
    if ((bandwidth < 500)); then
      buffer_mb=16
    elif ((bandwidth < 1000)); then
      buffer_mb=48
    else buffer_mb=64; fi
  else
    if ((bandwidth < 500)); then
      buffer_mb=8
    elif ((bandwidth < 1000)); then
      buffer_mb=12
    elif ((bandwidth < 2000)); then
      buffer_mb=16
    elif ((bandwidth < 5000)); then
      buffer_mb=24
    elif ((bandwidth < 10000)); then
      buffer_mb=28
    else buffer_mb=32; fi
  fi
  ((buffer_mb > cap_mb)) && buffer_mb="${cap_mb}"
  printf '%s' "${buffer_mb}"
}

apply_sysctls() {
  local buffer_bytes="$1" k v ok=true err=""
  local -a pairs=(
    net.core.rmem_max "${buffer_bytes}"
    net.core.wmem_max "${buffer_bytes}"
    net.core.default_qdisc fq
    net.ipv4.tcp_congestion_control bbr
    net.ipv4.tcp_rmem "4096 87380 ${buffer_bytes}"
    net.ipv4.tcp_wmem "4096 65536 ${buffer_bytes}"
    net.ipv4.tcp_limit_output_bytes 4194304
    net.ipv4.tcp_slow_start_after_idle 0
  )
  local i
  for ((i = 0; i < ${#pairs[@]}; i += 2)); do
    k="${pairs[i]}"
    v="${pairs[i + 1]}"
    if ! sysctl -w "${k}=${v}" >/dev/null 2>&1; then
      # 键不存在（精简内核）：无害，跳过；键存在但写入被拒：记失败
      if [ -n "$(sysctl -n "${k}" 2>/dev/null)" ]; then
        ok=false
        err="${err}${k} "
      fi
    fi
  done

  # 核心项写后回读校验（这些键所有常规内核均存在）
  [ "$(sysctl -n net.core.rmem_max 2>/dev/null)" = "${buffer_bytes}" ] || {
    ok=false
    err="${err}rmem_max "
  }
  [ "$(sysctl -n net.core.wmem_max 2>/dev/null)" = "${buffer_bytes}" ] || {
    ok=false
    err="${err}wmem_max "
  }
  [ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" = "fq" ] || {
    ok=false
    err="${err}default_qdisc "
  }
  [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ] || {
    ok=false
    err="${err}tcp_congestion_control "
  }
  [ "$(sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null)" = "4194304" ] || {
    ok=false
    err="${err}tcp_limit_output_bytes "
  }

  if [ -d /etc/sysctl.d ] && [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then
    {
      echo "# singbox-manager net_tune（v1.2.1 智能网络调优，重启后自动加载）"
      echo "net.core.rmem_max=${buffer_bytes}"
      echo "net.core.wmem_max=${buffer_bytes}"
      echo "net.core.default_qdisc=fq"
      echo "net.ipv4.tcp_congestion_control=bbr"
      echo "net.ipv4.tcp_rmem=4096 87380 ${buffer_bytes}"
      echo "net.ipv4.tcp_wmem=4096 65536 ${buffer_bytes}"
      echo "net.ipv4.tcp_limit_output_bytes=4194304"
      echo "net.ipv4.tcp_slow_start_after_idle=0"
    } >"/etc/sysctl.d/99-singbox-manager-net-tune.conf" 2>/dev/null
  fi

  if [ "${ok}" = "true" ]; then
    print_ok "已应用网络调优：BBR + fq + $((buffer_bytes / 1024 / 1024))MB 缓冲（tcp_limit_output_bytes=4MB、slow_start_after_idle=0），并已持久化到 /etc/sysctl.d/。"
  else
    print_warn "net_tune：sysctl 写入/回读校验失败（${err}），可能容器或精简内核限制不可调。"
  fi
}

apply_network_tune() {
  net_tune_requested || return 0
  [ "$(id -u 2>/dev/null || echo 1)" = "0" ] || return 0
  command_exists sysctl || return 0
  # 冒烟测试环境不执行真实 sysctl/测速（免网络依赖与副作用）
  if [ "${SBM_TEST_MODE:-0}" = "1" ]; then
    return 0
  fi
  local region bandwidth buffer_mb buffer_bytes cap_mb latency metric region_set
  local explicit_region

  # 地区档位：显式 net_tune_region 优先；否则首测时按延迟自动推断（v1.2.3）
  explicit_region="$(manager_env_or_setting "net_tune_region" "")"
  case "${explicit_region}" in
  asia | overseas) region="${explicit_region}" ;;
  *) region="" ;;
  esac

  buffer_mb="$(get_setting "net_tune_buffer_mb")"
  bandwidth="$(get_setting "net_tune_bandwidth_mbps")"
  if [ -n "${buffer_mb}" ] && [[ "${buffer_mb}" =~ ^[0-9]+$ ]]; then
    : # 沿用已测速并持久化的 buffer
  else
    # 首次运行：优先显式带宽，否则自动测速（含延迟），再按档位换算 buffer 并持久化
    bandwidth="${bandwidth:-}"
    if [ -z "${bandwidth}" ]; then
      bandwidth="$(env_var "net_tune_bandwidth_mbps")"
    fi
    latency=""
    if [ -n "${bandwidth}" ] && [[ "${bandwidth}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      : # 用户给定带宽，跳过测速
    elif [ -z "${NET_TUNE_SKIP_SPEEDTEST:-}" ]; then
      print_ok "net_tune：正在自动测速以智能优化 TCP 缓冲（首次运行，可 NET_TUNE_SKIP_SPEEDTEST=1 跳过）..."
      if metric="$(measure_net_metrics)"; then
        bandwidth="${metric%% *}"
        latency="${metric#* }"
        # 档位未显式设置时按延迟自动推断（延迟未知回退 asia）
        if [ -z "${region}" ]; then
          region="$(infer_net_tune_region "${latency}")"
          region_set="yes"
        fi
        # 交互确认：网络不佳时测速/延迟误差大，允许人工覆写（仅交互式终端）
        metric="$(net_tune_confirm_measurement "${bandwidth}" "${latency}" "${region}")"
        bandwidth="${metric%% *}"
        latency="${metric#* }"
        # 覆写后若档位为自动推断值，则按最新延迟重推
        if [ "${region_set:-}" = "yes" ]; then
          region="$(infer_net_tune_region "${latency}")"
        fi
        print_ok "net_tune：测速结果 带宽约 ${COLOR_NUM_HL}${bandwidth}${COLOR_RESET} Mbit/s${latency:+、延迟约 ${COLOR_NUM_HL}${latency}${COLOR_RESET} ms}（${region} 档）。"
      else
        print_warn "自动测速不可用（缺少 speedtest 或网络受限），按带宽 1000Mbps 档位优化。"
        bandwidth="1000"
      fi
    else
      bandwidth="1000"
    fi
    [ -z "${region}" ] && region="asia"
    cap_mb="$(get_tcp_buffer_cap_mb)"
    buffer_mb="$(calculate_net_tune_buffer_mb "${bandwidth}" "${region}")"
    set_setting "net_tune_bandwidth_mbps" "${bandwidth}"
    set_setting "net_tune_latency_ms" "${latency:-}"
    set_setting "net_tune_region" "${region}"
    set_setting "net_tune_buffer_mb" "${buffer_mb}"
    print_ok "net_tune：带宽约 ${COLOR_NUM_HL}${bandwidth}${COLOR_RESET} Mbps（${region} 档），内存上限 ${COLOR_NUM_HL}${cap_mb}${COLOR_RESET}MB，推荐 TCP 缓冲 ${COLOR_NUM_HL}${buffer_mb}${COLOR_RESET}MB。"
  fi

  buffer_bytes=$((buffer_mb * 1024 * 1024))
  apply_sysctls "${buffer_bytes}"
}

