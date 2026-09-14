#!/usr/bin/env bash
set -eEuo pipefail

umask 077

rollback_new_node() {
  local tag="$1"
  local cert_file="${2:-}"
  local key_file="${3:-}"
  delete_node_records "$tag" || true
  remove_node_certificates "$tag" "$cert_file" "$key_file"
  render_config || true
  start_service || true
}

save_node_bundle() {
  local tag="$1"
  local node_json="$2"
  local secret_json="$3"
  json_set_record "${NODES_FILE}" "$tag" "$node_json"
  json_set_record "${SECRETS_FILE}" "$tag" "$secret_json"
  invalidate_port_caches
}

render_config() {
  local inbounds_json tmp tags
  migrate_custom_certificates || return 1
  if ! tags="$(iter_node_tags)"; then
    print_err "读取节点列表失败。"
    return 1
  fi
  if ! inbounds_json="$(
    while IFS= read -r tag; do
      [ -n "${tag}" ] || continue
      render_inbound_for_tag "${tag}" || exit 1
    done <<<"$tags"
  )"; then
    print_err "生成 sing-box 入站配置失败。"
    return 1
  fi

  if [ -n "${inbounds_json}" ]; then
    if ! inbounds_json="$(printf '%s\n' "${inbounds_json}" | jq -s '.')"; then
      print_err "合并 sing-box 入站配置失败。"
      return 1
    fi
  else
    inbounds_json='[]'
  fi

  tmp="$(mktemp "${BASE_DIR}/.config.XXXXXX")"
  # 数据面日志等级可调（warn/info/debug），生产默认 warn 降低高负载磁盘 IO
  local log_level
  log_level="$(env_var "log_level")"
  case "${log_level}" in
  "info" | "debug") : ;;
  *) log_level="warn" ;;
  esac
  if ! jq -n --arg log_path "${BASE_DIR}/logs/sing-box.log" --arg log_level "${log_level}" --argjson inbounds "${inbounds_json}" '{
    log: {
      level: $log_level,
      timestamp: true,
      output: $log_path
    },
    inbounds: $inbounds,
    outbounds: [
      { type: "direct", tag: "direct" }
    ],
    route: {
      final: "direct",
      auto_detect_interface: true
    }
  }' >"${tmp}"; then
    rm -f "${tmp}"
    print_err "写入 sing-box 配置失败。"
    return 1
  fi
  # S4：落盘前用 sing-box 校验 tmp，失败则删除 tmp、保留旧配置并报错（fail-closed）
  if [ -n "${SINGBOX_BIN:-}" ] && [ -x "${SINGBOX_BIN}" ] && ! "${SINGBOX_BIN}" check -c "${tmp}" >/dev/null 2>&1; then
    rm -f "${tmp}"
    print_err "sing-box check 失败，已拒绝覆盖现有配置（旧配置保留）。"
    return 1
  fi
  if ! chmod 600 "${tmp}" || ! mv "${tmp}" "${CONFIG_FILE}"; then
    rm -f "${tmp}"
    print_err "保存 sing-box 配置失败。"
    return 1
  fi
}

node_meta() {
  local tag="$1"
  # 单进程 jq 合并 nodes+secrets 输出 25 个字段（每行一个，空值输出空行），
  # 字段路径与 node_value/secret_value（.[$tag][$field]）完全一致；
  # 渲染/分享链接按节点仅启动 1 次 jq，替代逐字段 node_value/secret_value 的多次启动。
  # 输出用"每行一个字段"而非 tab 分隔：bash 的 read/cut 会合并连续 tab 并吞掉空字段，
  # 空行则能被 while read 完整保留。
  jq -n -r --arg tag "$tag" \
    --rawfile nodes "${NODES_FILE}" \
    --rawfile secrets "${SECRETS_FILE}" '
    ($nodes | fromjson | .[$tag] // {}) as $n |
    ($secrets | fromjson | .[$tag] // {}) as $s |
    [
      ($n.protocol // ""),
      ($n.name // ""),
      (($n.port // "") | tostring),
      ($s.uuid // ""),
      ($s.password // ""),
      ($s.private_key // ""),
      ($n.public_key // ""),
      ($n.short_id // ""),
      ($n.reality_server // ""),
      ($n.tls_server // ""),
      ($n.preferred_domain // ""),
      ($n.host_domain // ""),
      ($n.ws_path // ""),
      ($n.ws_mode // ""),
      (($n.cdn_port // "") | tostring),
      ($n.cdn_sni // ""),
      ($n.certificate_mode // ""),
      ($n.certificate_path // ""),
      ($n.key_path // ""),
      ($n.endpoint_domain // ""),
      ($n.argo_mode // ""),
      ($s.argo_token // ""),
      (($n.up_mbps // "") | tostring),
      (($n.down_mbps // "") | tostring),
      ($n.username // "")
    ] | .[]
  '
}

node_meta_array() {
  local tag="$1" i=0 _f
  NODE_META=()
  while IFS= read -r _f; do
    NODE_META[i++]="${_f%$'\r'}"
    [ "$i" -ge 25 ] && break
  done < <(node_meta "$tag")
  while [ "$i" -lt 25 ]; do NODE_META[i++]=""; done
}

render_inbound_for_tag() {
  local tag="$1"
  local protocol name port uuid password cert_file key_file ws_path reality_server tcp_fast_open
  local up_mbps down_mbps bbr_profile private_key short_id
  local __tfo

  # 单次 jq 批量取出 nodes+secrets 全部字段，替代逐字段 node_value/secret_value（每节点省多次 jq 启动）
  node_meta_array "$tag"
  protocol="${NODE_META[0]}"
  name="${NODE_META[1]}"
  port="${NODE_META[2]}"
  uuid="${NODE_META[3]}"
  password="${NODE_META[4]}"
  private_key="${NODE_META[5]}"
  short_id="${NODE_META[7]}"
  reality_server="${NODE_META[8]}"
  ws_path="${NODE_META[12]}"
  ws_mode="${NODE_META[13]}"
  cert_mode="${NODE_META[16]}"
  cert_file="${NODE_META[17]}"
  key_file="${NODE_META[18]}"
  up_mbps="${NODE_META[22]}"
  down_mbps="${NODE_META[23]}"
  username="${NODE_META[24]}"
  # 全局 TCP Fast Open（默认开启，1.14.0 各 TCP 入站均支持）
  case "$(env_var "tcp_fast_open")" in
  "" | 1) __tfo=true ;;
  *) __tfo=false ;;
  esac

  case "$protocol" in
  vless-reality)
    jq -n \
      --arg tag "$tag" \
      --arg name "$name" \
      --arg uuid "$uuid" \
      --arg server "$reality_server" \
      --arg private_key "$private_key" \
      --arg short_id "$short_id" \
      --argjson port "$port" \
      --argjson tfo "${__tfo}" '{
          type: "vless",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          tcp_fast_open: $tfo,
          users: [{ name: $name, uuid: $uuid, flow: "xtls-rprx-vision" }],
          tls: {
            enabled: true,
            server_name: $server,
            reality: {
              enabled: true,
              handshake: { server: $server, server_port: 443 },
              private_key: $private_key,
              short_id: [$short_id]
            }
          }
        }'
    ;;
  vless-ws-tls)
    # 主 inbound：TLS 端口（v1.2.4 起 CDN 模式统一单端口：客户端连 CDN 边缘，CF 按 SSL 模式
    # Full/Full(Strict) 以 HTTPS 回源到本 TLS 端口，无需明文回源 inbound）。
    jq -n \
      --arg tag "$tag" \
      --arg name "$name" \
      --arg uuid "$uuid" \
      --arg ws_path "$ws_path" \
      --arg cert_file "$cert_file" \
      --arg key_file "$key_file" \
      --argjson port "$port" \
      --argjson tfo "${__tfo}" '{
          type: "vless",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          tcp_fast_open: $tfo,
          users: [{ name: $name, uuid: $uuid }],
          tls: {
            enabled: true,
            certificate_path: $cert_file,
            key_path: $key_file
          },
          transport: { type: "ws", path: $ws_path, max_early_data: 2048, early_data_header_name: "Sec-WebSocket-Protocol" }
        }'
    ;;
  anytls)
    jq -n \
      --arg tag "$tag" \
      --arg name "$name" \
      --arg password "$password" \
      --arg cert_file "$cert_file" \
      --arg key_file "$key_file" \
      --argjson port "$port" \
      --argjson tfo "${__tfo}" '{
          type: "anytls",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          tcp_fast_open: $tfo,
          users: [{ name: $name, password: $password }],
          tls: {
            enabled: true,
            certificate_path: $cert_file,
            key_path: $key_file
          }
        }'
    ;;
  vless-argo)
    jq -n \
      --arg tag "$tag" \
      --arg name "$name" \
      --arg uuid "$uuid" \
      --arg ws_path "$ws_path" \
      --argjson port "$port" \
      --argjson tfo "${__tfo}" '{
          type: "vless",
          tag: $tag,
          listen: "127.0.0.1",
          listen_port: $port,
          tcp_fast_open: $tfo,
          users: [{ name: $name, uuid: $uuid }],
          transport: { type: "ws", path: $ws_path, max_early_data: 2048, early_data_header_name: "Sec-WebSocket-Protocol" }
        }'
    ;;
  tuic-v5)
    jq -n \
      --arg tag "$tag" \
      --arg name "$name" \
      --arg uuid "$uuid" \
      --arg password "$password" \
      --arg cert_file "$cert_file" \
      --arg key_file "$key_file" \
      --argjson port "$port" '{
          type: "tuic",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          users: [{ name: $name, uuid: $uuid, password: $password }],
          congestion_control: "bbr",
          zero_rtt_handshake: false,
          heartbeat: "10s",
          tls: {
            enabled: true,
            alpn: ["h3"],
            certificate_path: $cert_file,
            key_path: $key_file
          }
        }'
    ;;
  hy2)
    up_mbps="${up_mbps:-200}"
    down_mbps="${down_mbps:-200}"
    # 全局 bbr_profile：aggressive|standard|conservative（sing-box 1.14.0+），空=默认
    bbr_profile="$(env_var "bbr_profile")"
    case "${bbr_profile}" in
    aggressive | standard | conservative) : ;;
    *) bbr_profile="" ;;
    esac
    # 默认上下行 200 Mbps（未显式设置时）；bbr_profile 留空用 sing-box 默认
    jq -n \
      --arg tag "$tag" \
      --arg name "$name" \
      --arg password "$password" \
      --arg cert_file "$cert_file" \
      --arg key_file "$key_file" \
      --argjson up_mbps "${up_mbps:-0}" \
      --argjson down_mbps "${down_mbps:-0}" \
      --arg bbr_profile "${bbr_profile}" \
      --argjson port "$port" '{
          type: "hysteria2",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          users: [{ name: $name, password: $password }],
          tls: {
            enabled: true,
            alpn: ["h3"],
            certificate_path: $cert_file,
            key_path: $key_file
          }
        }
        + (if ($up_mbps > 0) then { up_mbps: $up_mbps } else {} end)
        + (if ($down_mbps > 0) then { down_mbps: $down_mbps } else {} end)
        + (if ($bbr_profile != "") then { bbr_profile: $bbr_profile } else {} end)'
    ;;
  socks5)
    jq -n \
      --arg tag "$tag" \
      --arg username "$username" \
      --arg password "$password" \
      --argjson port "$port" \
      --argjson tfo "${__tfo}" '{
          type: "socks",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          tcp_fast_open: $tfo,
          users: [{ username: $username, password: $password }]
        }'
    ;;
  *)
    print_err "不支持的节点协议：${protocol}"
    return 1
    ;;
  esac
}

