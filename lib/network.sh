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

  # A1：同族多源并行探测（SBM_IP_PROBE_PARALLEL=0 回退串行），首个合法公网 IP 即回，
  # 冷启动最坏耗时从 4×5s 降到 ≈5s（每 curl --max-time 5 为硬上限）。
  local -a probe_urls=()
  local probe_tmp rawip _u _i _f
  for ipver in "${families[@]}"; do
    if [ "${ipver}" = "4" ]; then
      flag="--ipv4"
      probe_urls=("https://api.ipify.org" "https://ipv4.icanhazip.com")
    else
      flag="--ipv6"
      probe_urls=("https://api64.ipify.org" "https://ipv6.icanhazip.com")
    fi

    if [ "${SBM_IP_PROBE_PARALLEL:-1}" = "1" ] && [ "${#probe_urls[@]}" -gt 1 ]; then
      probe_tmp="$(mktemp -d "${BASE_DIR}/.ipprobe.XXXXXX" 2>/dev/null || true)"
      [ -n "${probe_tmp}" ] || probe_tmp="$(mktemp -d 2>/dev/null || true)"
      [ -n "${probe_tmp}" ] || probe_tmp="${TMPDIR:-/tmp}/ipprobe.$$"
      mkdir -p "${probe_tmp}"
      _i=0
      for _u in "${probe_urls[@]}"; do
        (curl -fsS --max-time 5 ${flag} "$_u" 2>/dev/null | tr -d '\r\n') >"${probe_tmp}/${_i}" &
        _i=$((_i + 1))
      done
      wait || true
      for _f in "${probe_tmp}"/*; do
        [ -f "${_f}" ] || continue
        rawip="$(tr -d '\r\n' <"${_f}" 2>/dev/null || true)"
        if is_ip_address "${rawip}" && ! is_private_ip "${rawip}"; then
          rm -rf "${probe_tmp}"
          PUBLIC_IP_CACHE="${rawip}"
          set_setting "public_ip" "${rawip}"
          set_setting "public_ip_version" "${ipver}"
          set_setting "public_ip_ts" "$now"
          printf '%s' "${PUBLIC_IP_CACHE}"
          return 0
        fi
      done
      rm -rf "${probe_tmp}"
    else
      for url in "${probe_urls[@]}"; do
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

# P2：TCP 类节点协议 —— 探活/就绪自检只对它们有意义。
# tuic-v5 与 hy2 为纯 UDP(QUIC) 监听，TCP 探活永远失败，绝不能纳入探活集。
tcp_probeable_protocol() {
  local protocol="$1"
  case "${protocol}" in
  vless-reality | vless-ws-tls | anytls | vless-argo | socks5) return 0 ;;
  esac
  return 1
}

# P2：当前 TCP 可探活节点数量（无节点或无 TCP 类节点时输出 0）。
tcp_probeable_node_count() {
  local tag protocol cnt=0
  [ -f "${NODES_FILE}" ] || {
    printf '0'
    return 0
  }
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    protocol="$(node_value "$tag" "protocol")"
    if tcp_probeable_protocol "${protocol}"; then
      cnt=$((cnt + 1))
    fi
  done < <(iter_node_tags)
  printf '%s' "${cnt}"
}

any_node_port_alive() {
  local tag port protocol _status=1
  local -a jobs=()
  [ -f "${NODES_FILE}" ] || return 1
  if [ "${SBM_PROBE_PARALLEL:-1}" = "1" ]; then
    # A2：全节点端口并行探活，任一成功即判定存活；
    # 10 个死节点从串行 ≈20s 降到 ≈SBM_PROBE_TIMEOUT_S（默认 2s）。
    # P2：仅探 TCP 类协议，hy2/tuic 纯 UDP 节点一律跳过（TCP 探活不适用）。
    while IFS= read -r tag; do
      [ -n "${tag}" ] || continue
      protocol="$(node_value "$tag" "protocol" 2>/dev/null || true)"
      if ! tcp_probeable_protocol "${protocol}"; then
        continue
      fi
      port="$(node_value "$tag" "port" 2>/dev/null || true)"
      [ -n "${port}" ] || continue
      probe_tcp_port "127.0.0.1" "${port}" "${SBM_PROBE_TIMEOUT_S:-2}" &
      jobs+=("$!")
    done < <(iter_node_tags)
    if [ "${#jobs[@]}" -eq 0 ]; then
      return 1
    fi
    for port in "${jobs[@]}"; do
      wait "${port}" 2>/dev/null && _status=0 || true
    done
    [ "${_status}" = 0 ] && return 0
    return 1
  fi
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    protocol="$(node_value "$tag" "protocol" 2>/dev/null || true)"
    if ! tcp_probeable_protocol "${protocol}"; then
      continue
    fi
    port="$(node_value "$tag" "port" 2>/dev/null || true)"
    [ -n "${port}" ] || continue
    if probe_tcp_port "127.0.0.1" "${port}" "${SBM_PROBE_TIMEOUT_S:-2}"; then
      return 0
    fi
  done < <(iter_node_tags)
  return 1
}

# P2：数据面探活三态。
#   0=有 TCP 节点且任一可探活（健康）
#   1=存在 TCP 节点但全部不可探活（假死候选）
#   2=无可 TCP 探活节点（全 UDP/空，不适用，调用方以进程存活为准）
singbox_probe_status() {
  local cnt
  cnt="$(tcp_probeable_node_count)"
  [ "${cnt}" -gt 0 ] || return 2
  if any_node_port_alive; then
    return 0
  fi
  return 1
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

