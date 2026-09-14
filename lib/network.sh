#!/usr/bin/env bash
set -eEuo pipefail

umask 077

get_public_ip() {
  local ip ipver flag url
  local cached cached_ts now ttl cached_ver

  if [ -n "${PUBLIC_IP_CACHE}" ]; then
    printf '%s' "${PUBLIC_IP_CACHE}"
    return 0
  fi

  # 分享链接默认使用 IPv4；全局设置 ip_version 可选 auto(=v4 优先) / 4 / 6
  ipver="$(get_setting "ip_version" "4")"
  case "${ipver,,}" in
  6 | v6) ipver="6" ;;
  *) ipver="4" ;;
  esac

  # 持久化缓存：settings.json 的 public_ip/public_ip_ts 在 TTL 内且 ip 版本匹配时直接复用，
  # 避免 sbm list/sub/show_status 每次启动都外呼公网探测服务（SBM_IP_CACHE_TTL 秒，默认 600）。
  ttl="${SBM_IP_CACHE_TTL:-600}"
  cached="$(get_setting "public_ip")"
  cached_ts="$(get_setting "public_ip_ts")"
  cached_ver="$(get_setting "public_ip_version")"
  now="$(date +%s 2>/dev/null || printf 0)"
  if [ -n "${cached}" ] && is_ip_address "${cached}" && ! is_private_ip "${cached}" &&
    { [ -z "${cached_ver}" ] || [ "${cached_ver}" = "${ipver}" ]; } &&
    { [ "${now}" -eq 0 ] || { [[ "${cached_ts}" =~ ^[0-9]+$ ]] && [ $((now - cached_ts)) -lt "${ttl}" ]; }; }; then
    PUBLIC_IP_CACHE="${cached}"
    printf '%s' "${PUBLIC_IP_CACHE}"
    return 0
  fi

  local families=(4 6)
  if [ "${ipver}" = "6" ]; then
    families=(6 4)
  fi

  for ipver in "${families[@]}"; do
    if [ "${ipver}" = "4" ]; then
      flag="--ipv4"
      for url in "https://api.ipify.org" "https://ipv4.icanhazip.com"; do
        ip="$(curl -fsS --max-time 5 ${flag} "$url" 2>/dev/null | tr -d '\r\n' || true)"
        if is_ip_address "$ip" && ! is_private_ip "$ip"; then
          PUBLIC_IP_CACHE="$ip"
          set_setting "public_ip" "$ip"
          set_setting "public_ip_version" "${ipver}"
          set_setting "public_ip_ts" "$now"
          printf '%s' "${PUBLIC_IP_CACHE}"
          return 0
        fi
      done
    else
      flag="--ipv6"
      for url in "https://api64.ipify.org" "https://ipv6.icanhazip.com"; do
        ip="$(curl -fsS --max-time 5 ${flag} "$url" 2>/dev/null | tr -d '\r\n' || true)"
        if is_ip_address "$ip" && ! is_private_ip "$ip"; then
          PUBLIC_IP_CACHE="$ip"
          set_setting "public_ip" "$ip"
          set_setting "public_ip_version" "${ipver}"
          set_setting "public_ip_ts" "$now"
          printf '%s' "${PUBLIC_IP_CACHE}"
          return 0
        fi
      done
    fi
  done

  local fallback=""
  for ip in $(hostname -I 2>/dev/null || true); do
    if is_ip_address "$ip" && ! is_private_ip "$ip"; then
      PUBLIC_IP_CACHE="$ip"
      printf '%s' "${PUBLIC_IP_CACHE}"
      return 0
    fi
    [ -n "${fallback}" ] || fallback="$ip"
  done

  fallback="${fallback:-127.0.0.1}"
  print_warn "无法探测公网 IP，已回退到本机地址：${fallback}"
  PUBLIC_IP_CACHE="$fallback"
  printf '%s' "${PUBLIC_IP_CACHE}"
}

probe_tcp_port() {
  local host="$1"
  local port="${2:-}"
  local timeout_s="${3:-2}"
  [ -n "${port}" ] || return 1
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  if command_exists timeout; then
    timeout "${timeout_s}" bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1
  else
    # 环境无 timeout：直接尝试，尽力而为
    bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1
  fi
}

any_node_port_alive() {
  local tag port alive=1
  [ -f "${NODES_FILE}" ] || return 1
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    port="$(node_value "$tag" "port" 2>/dev/null || true)"
    [ -n "${port}" ] || continue
    if probe_tcp_port "127.0.0.1" "${port}" "${SBM_PROBE_TIMEOUT_S:-2}"; then
      alive=0
      break
    fi
  done < <(iter_node_tags)
  [ "${alive}" = 0 ] || return 1
  return 0
}

has_public_ipv4() {
  if [ -n "${HAS_PUBLIC_IPV4}" ]; then
    [ "${HAS_PUBLIC_IPV4}" = "yes" ]
    return
  fi

  local ip
  ip="$(curl -fsS --max-time 5 --ipv4 "https://api64.ipify.org" 2>/dev/null | tr -d '\r\n' || true)"
  if is_ip_address "${ip}" && ! is_private_ip "${ip}"; then
    HAS_PUBLIC_IPV4="yes"
    return 0
  fi

  HAS_PUBLIC_IPV4="no"
  return 1
}


invalidate_port_caches() {
  _METADATA_PORTS=""
  _SYSTEM_PORTS=""
}

snapshot_metadata_ports() {
  [ -n "${_METADATA_PORTS:-}" ] && return 0
  _METADATA_PORTS="$(jq -r '.. | objects | .port? // empty' "${NODES_FILE}" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' | sort -nu | tr '\n' ' ' || true)"
  : "${_METADATA_PORTS:=}"
}

snapshot_system_ports() {
  [ -n "${_SYSTEM_PORTS:-}" ] && return 0
  if command_exists ss; then
    _SYSTEM_PORTS="$(ss -ltnuH 2>/dev/null | awk '$1 ~ /^(tcp|tcp6|udp|udp6)$/ { t=$4; sub(/.*:/,"",t); if (t ~ /^[0-9]+$/) print t }' | sort -nu | tr '\n' ' ' || true)"
  elif command_exists netstat; then
    _SYSTEM_PORTS="$(netstat -lntup 2>/dev/null | awk '$1 ~ /^(tcp|tcp6|udp|udp6)$/ { t=$4; sub(/.*:/,"",t); if (t ~ /^[0-9]+$/) print t }' | sort -nu | tr '\n' ' ' || true)"
  fi
  : "${_SYSTEM_PORTS:=}"
}

metadata_has_port() {
  local port="$1"
  snapshot_metadata_ports
  [[ " ${_METADATA_PORTS} " == *" ${port} "* ]]
}

system_has_port() {
  local port="$1"
  snapshot_system_ports
  [[ " ${_SYSTEM_PORTS} " == *" ${port} "* ]]
}

port_available() {
  local port="$1"
  if metadata_has_port "$port"; then
    return 1
  fi
  if system_has_port "$port"; then
    return 1
  fi
  return 0
}

