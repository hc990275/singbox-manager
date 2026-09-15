#!/usr/bin/env bash
set -eEuo pipefail

umask 077

find_ookla_speedtest() {
  local bin
  if command_exists speedtest && speedtest --version 2>/dev/null | grep -q "Speedtest by Ookla"; then
    command -v speedtest
    return 0
  fi
  bin="${BASE_DIR}/bin/speedtest"
  if [ -x "${bin}" ] && "${bin}" --version 2>/dev/null | grep -q "Speedtest by Ookla"; then
    printf '%s' "${bin}"
    return 0
  fi
  return 1
}

speedtest_download_url() {
  case "$(uname -m)" in
  x86_64) printf 'https://install.speedtest.net/app/cli/ookla-speedtest-%s-linux-x86_64.tgz' "${OOKLA_SPEEDTEST_VERSION}" ;;
  aarch64) printf 'https://install.speedtest.net/app/cli/ookla-speedtest-%s-linux-aarch64.tgz' "${OOKLA_SPEEDTEST_VERSION}" ;;
  *) return 1 ;;
  esac
}

ensure_ookla_speedtest() {
  local bin url tmp_dir
  [ -n "${NET_TUNE_SKIP_SPEEDTEST:-}" ] && return 1
  command_exists curl || command_exists wget || return 1
  command_exists tar || return 1
  url="$(speedtest_download_url)" || return 1
  mkdir -p "${BASE_DIR}/bin"
  bin="${BASE_DIR}/bin/speedtest"
  tmp_dir="$(mktemp -d "${BASE_DIR}/bin/.st.XXXXXX" 2>/dev/null)" || return 1
  if command_exists curl; then
    curl -fsSL --retry 2 --connect-timeout 10 --max-time 90 "${url}" -o "${tmp_dir}/t.tgz" || {
      rm -rf "${tmp_dir}"
      return 1
    }
  else
    wget -q --tries=2 --timeout=90 -O "${tmp_dir}/t.tgz" "${url}" || {
      rm -rf "${tmp_dir}"
      return 1
    }
  fi
  tar -xzf "${tmp_dir}/t.tgz" -C "${tmp_dir}" || {
    rm -rf "${tmp_dir}"
    return 1
  }
  mv -f "${tmp_dir}/speedtest" "${bin}" && chmod 0755 "${bin}"
  rm -rf "${tmp_dir}"
  "${bin}" --version 2>/dev/null | grep -q "Speedtest by Ookla" || {
    rm -f "${bin}"
    return 1
  }
  return 0
}

run_speedtest() {
  local bin="$1" out up json_up
  # 9.1：优先 JSON 输出（bandwidth 为 bit/s，/1e6 得 Mbps），解析失败回退人类文本
  out="$("${bin}" --accept-license --accept-gdpr --output-type=json 2>/dev/null || true)"
  if [ -n "${out}" ]; then
    json_up="$(printf '%s' "${out}" | jq -r '.upload.bandwidth // empty' 2>/dev/null || true)"
    if [[ "${json_up}" =~ ^[0-9]+$ ]] && [ "${json_up}" -gt 0 ]; then
      printf '%s' "$((json_up / 1000000))"
      return 0
    fi
  fi
  out="$("${bin}" --accept-license --accept-gdpr 2>&1 || true)"
  up="$(printf '%s' "${out}" | sed -nE 's/.*[Uu]pload:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)"
  if [[ "${up}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && ! printf '%s' "${out}" | grep -qi 'FAILED\|error'; then
    printf '%s' "${up%.*}"
    return 0
  fi
  return 1
}

run_speedtest_metrics() {
  local bin="$1" out up lat json_up json_lat
  # 9.1：JSON 输出读取 upload.bandwidth（bit/s，/1e6 得 Mbps）与 ping.latency（ms），
  # 解析失败回退人类文本（老版本/受限环境）
  out="$("${bin}" --accept-license --accept-gdpr --output-type=json 2>/dev/null || true)"
  if [ -n "${out}" ]; then
    json_up="$(printf '%s' "${out}" | jq -r '.upload.bandwidth // empty' 2>/dev/null || true)"
    if [[ "${json_up}" =~ ^[0-9]+$ ]] && [ "${json_up}" -gt 0 ]; then
      json_lat="$(printf '%s' "${out}" | jq -r '.ping.latency // empty' 2>/dev/null || true)"
      [[ "${json_lat}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || json_lat=""
      printf '%s %s' "$((json_up / 1000000))" "${json_lat%.*}"
      return 0
    fi
  fi
  out="$("${bin}" --accept-license --accept-gdpr 2>&1 || true)"
  up="$(printf '%s' "${out}" | sed -nE 's/.*[Uu]pload:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)"
  lat="$(printf '%s' "${out}" | sed -nE 's/.*[Ll]atency:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)"
  if [[ "${up}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && ! printf '%s' "${out}" | grep -qi 'FAILED\|error'; then
    printf '%s %s' "${up%.*}" "${lat%.[0-9]*}"
    return 0
  fi
  return 1
}

measure_net_bandwidth() {
  local bin up
  if ! bin="$(find_ookla_speedtest)"; then
    ensure_ookla_speedtest || return 1
    bin="$(find_ookla_speedtest)" || return 1
  fi
  if command_exists timeout; then
    if [ -n "${NET_TUNE_SPEEDTEST_TIMEOUT:-}" ]; then
      up="$(timeout "${NET_TUNE_SPEEDTEST_TIMEOUT}" bash -c "$(declare -f run_speedtest); run_speedtest '$bin'" 2>/dev/null || true)"
    else
      up="$(timeout 90 bash -c "$(declare -f run_speedtest); run_speedtest '$bin'" 2>/dev/null || true)"
    fi
  else
    up="$(run_speedtest "${bin}" 2>/dev/null || true)"
  fi
  [[ "${up}" =~ ^[0-9]+$ ]] && {
    printf '%s' "${up}"
    return 0
  }
  return 1
}

measure_net_metrics() {
  local bin out up lat
  if ! bin="$(find_ookla_speedtest)"; then
    ensure_ookla_speedtest || return 1
    bin="$(find_ookla_speedtest)" || return 1
  fi
  if command_exists timeout; then
    if [ -n "${NET_TUNE_SPEEDTEST_TIMEOUT:-}" ]; then
      out="$(timeout "${NET_TUNE_SPEEDTEST_TIMEOUT}" bash -c "$(declare -f run_speedtest_metrics); run_speedtest_metrics '$bin'" 2>/dev/null || true)"
    else
      out="$(timeout 90 bash -c "$(declare -f run_speedtest_metrics); run_speedtest_metrics '$bin'" 2>/dev/null || true)"
    fi
  else
    out="$(run_speedtest_metrics "${bin}" 2>/dev/null || true)"
  fi
  up="${out%% *}"
  lat="${out#* }"
  [[ "${up}" =~ ^[0-9]+$ ]] && {
    printf '%s %s' "${up}" "${lat}"
    return 0
  }
  return 1
}

infer_net_tune_region() {
  local latency="${1:-}"
  if [[ "${latency}" =~ ^[0-9]+$ ]] && [ "${latency}" -ge 150 ]; then
    printf '%s' "overseas"
  else
    printf '%s' "asia"
  fi
}

net_tune_confirm_measurement() {
  local bandwidth="$1" latency="$2" region="$3" cap_mb buffer_mb
  local answer new_bw new_lat
  if [ "${SBM_TEST_MODE:-0}" = "1" ] || [ ! -t 0 ] || [ "${NET_TUNE_SKIP_CONFIRM:-0}" = "1" ]; then
    printf '%s %s' "${bandwidth}" "${latency}"
    return 0
  fi
  cap_mb="$(get_tcp_buffer_cap_mb)"
  buffer_mb="$(calculate_net_tune_buffer_mb "${bandwidth}" "${region}")"
  echo >&2
  print_info "net_tune 自动测速结果：约 ${COLOR_NUM_HL}${bandwidth}${COLOR_RESET} Mbps${latency:+，延迟约 ${COLOR_NUM_HL}${latency}${COLOR_RESET} ms}（${region} 档）。" >&2
  print_info "推荐 TCP 缓冲：${COLOR_NUM_HL}${buffer_mb}${COLOR_RESET}MB（内存上限 ${COLOR_NUM_HL}${cap_mb}${COLOR_RESET}MB 内）。" >&2
  while true; do
    print_info "网络不佳时自动测速常有误差，可输入  新带宽 新延迟  覆写。" >&2
    read -r -p "直接回车确认，或输入新值（格式：带宽 延迟，如 500 120）: " answer || true
    answer="$(printf '%s' "${answer}" | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [ -z "${answer}" ]; then
      break
    fi
    new_bw="$(printf '%s' "${answer}" | awk '{print $1}')"
    new_lat="$(printf '%s' "${answer}" | awk '{print $2}')"
    if [[ "${new_bw}" =~ ^[0-9]+$ ]] && [ "${new_bw}" -gt 0 ]; then
      bandwidth="${new_bw}"
      [[ "${new_lat}" =~ ^[0-9]+$ ]] && latency="${new_lat}"
      if [ -n "${latency}" ]; then
        print_ok "已覆写：带宽 ${COLOR_NUM_HL}${bandwidth}${COLOR_RESET} Mbps，延迟 ${COLOR_NUM_HL}${latency}${COLOR_RESET} ms。" >&2
      else
        print_ok "已覆写：带宽 ${COLOR_NUM_HL}${bandwidth}${COLOR_RESET} Mbps，延迟 未测 ms。" >&2
      fi
      break
    fi
    print_warn "输入无效，应为两个正整数（带宽 延迟）。"
  done
  printf '%s %s' "${bandwidth}" "${latency}"
}
