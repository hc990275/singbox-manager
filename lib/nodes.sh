#!/usr/bin/env bash
set -eEuo pipefail

umask 077

# 本文件由 sb.sh 模块拆分生成：函数自原 sb.sh 原样迁出（见各自函数上方注释）。
# 依赖 lib/common.sh 提供的基础函数与全局变量，须在 common.sh 之后被 source。

metadata_has_port() {
  local port="$1"
  jq -e --argjson port "$port" 'to_entries | any(.value.port == $port)' "${NODES_FILE}" >/dev/null 2>&1
}

system_has_port() {
  local port="$1"
  if command_exists ss; then
    ss -ltnuH 2>/dev/null | awk -v port="$port" '
      $1 ~ /^(tcp|tcp6|udp|udp6)$/ {
        addr = $5; sub(/.*:/, "", addr); if (addr == port) found = 1
      }
      END { exit found ? 0 : 1 }
    '
  elif command_exists netstat; then
    netstat -lntup 2>/dev/null | awk -v port="$port" '
      $1 ~ /^(tcp|tcp6|udp|udp6)$/ {
        addr = $4; sub(/.*:/, "", addr); if (addr == port) found = 1
      }
      END { exit found ? 0 : 1 }'
  else
    return 1
  fi
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

managed_cert_path() {
  local tag="$1"
  local path="$2"
  [ "${path%/*}" = "${CERT_DIR}" ] || return 1
  case "$path" in
  "${CERT_DIR}/${tag}."*/*) return 1 ;;
  "${CERT_DIR}/${tag}."*) return 0 ;;
  *) return 1 ;;
  esac
}

import_custom_certificate_bundle() {
  local tag="$1"
  local cert_path="$2"
  local key_path="$3"
  local cert_file="${CERT_DIR}/${tag}.custom.crt"
  local key_file="${CERT_DIR}/${tag}.custom.key"
  local cert_copied=false

  if [ "$cert_path" != "$cert_file" ]; then
    cp "$cert_path" "$cert_file" || return 1
    cert_copied=true
  fi
  if [ "$key_path" != "$key_file" ]; then
    cp "$key_path" "$key_file" || {
      if [ "$cert_copied" = true ]; then
        rm -f "$cert_file"
      fi
      return 1
    }
  fi
  chmod 600 "$cert_file" "$key_file"
  printf '%s|%s' "$cert_file" "$key_file"
}

# v1.2.5：从界面粘贴的 PEM 内容（base64）直接写入托管证书目录，无需先上传文件
import_custom_certificate_content() {
  local tag="$1"
  local cert_b64="$2"
  local key_b64="$3"
  local cert_file="${CERT_DIR}/${tag}.custom.crt"
  local key_file="${CERT_DIR}/${tag}.custom.key"

  if [ -z "$cert_b64" ] || [ -z "$key_b64" ]; then
    return 1
  fi
  printf '%s' "$cert_b64" | base64 -d >"$cert_file" || return 1
  printf '%s' "$key_b64" | base64 -d >"$key_file" || { rm -f "$cert_file"; return 1; }
  chmod 600 "$cert_file" "$key_file"
  printf '%s|%s' "$cert_file" "$key_file"
}

remove_node_certificates() {
  local tag="$1"
  local cert_file="${2:-}"
  local key_file="${3:-}"

  if [ -n "$cert_file" ] && [ -f "$cert_file" ] && managed_cert_path "$tag" "$cert_file"; then
    rm -f "$cert_file"
  fi
  if [ -n "$key_file" ] && [ -f "$key_file" ] && managed_cert_path "$tag" "$key_file"; then
    rm -f "$key_file"
  fi
}

migrate_custom_certificate_bundle() {
  local tag="$1"
  local cert_mode cert_file key_file pair

  cert_mode="$(node_value "$tag" "certificate_mode")"
  [ "$cert_mode" = "custom" ] || return 0

  cert_file="$(node_value "$tag" "certificate_path")"
  key_file="$(node_value "$tag" "key_path")"
  if managed_cert_path "$tag" "$cert_file" && managed_cert_path "$tag" "$key_file"; then
    return 0
  fi
  if [ ! -r "$cert_file" ] || [ ! -r "$key_file" ]; then
    print_err "自定义证书不可读取，无法导入托管目录：${tag}"
    return 1
  fi

  pair="$(import_custom_certificate_bundle "$tag" "$cert_file" "$key_file")" || return 1
  json_set_field "${NODES_FILE}" "$tag" "certificate_path" "${pair%|*}" || return 1
  json_set_field "${NODES_FILE}" "$tag" "key_path" "${pair#*|}" || return 1
}

migrate_custom_certificates() {
  local tags tag
  if ! tags="$(iter_node_tags)"; then
    print_err "读取节点列表失败。"
    return 1
  fi
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    migrate_custom_certificate_bundle "$tag" || return 1
  done <<<"$tags"
}

cleanup_argo_pid() {
  local pid_file="$1"
  kill_pid_file "$pid_file"
}

prompt_certificate_bundle() {
  local tag="$1"
  local default_domain="$2"
  local mode cert_path key_path pair

  while true; do
    mode="$(prompt_choice "证书模式 (self-signed/custom)" "self-signed")"
    case "$mode" in
    self-signed | self | quick)
      pair="$(ensure_tls_material "$tag" "$default_domain")"
      printf 'self-signed|%s|%s' "${pair%|*}" "${pair#*|}"
      return 0
      ;;
    custom)
      cert_path="$(prompt_nonempty "证书路径")"
      key_path="$(prompt_nonempty "私钥路径")"
      [ -r "$cert_path" ] || {
        print_warn "证书不可读取：${cert_path}"
        continue
      }
      [ -r "$key_path" ] || {
        print_warn "私钥不可读取：${key_path}"
        continue
      }
      if ! pair="$(import_custom_certificate_bundle "$tag" "$cert_path" "$key_path")"; then
        print_warn "导入自定义证书失败，请检查路径和权限。"
        continue
      fi
      printf 'custom|%s|%s' "${pair%|*}" "${pair#*|}"
      return 0
      ;;
    *)
      print_warn "请输入 self-signed 或 custom。"
      ;;
    esac
  done
}

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

express_restart() { :; }
  jq_eno() { :; }
  render_inbound_for_tag() {
  local tag="$1"
  local protocol name port uuid password cert_file key_file ws_path reality_server tcp_fast_open
  local up_mbps down_mbps bbr_profile
  local __tfo

  protocol="$(node_value "$tag" "protocol")"
  name="$(node_value "$tag" "name")"
  port="$(node_value "$tag" "port")"
  # 全局 TCP Fast Open（默认开启，1.14.0 各 TCP 入站均支持）
  case "$(env_var "tcp_fast_open")" in
  "" | 1) __tfo=true ;;
  *) __tfo=false ;;
  esac

  case "$protocol" in
  vless-reality)
    uuid="$(secret_value "$tag" "uuid")"
    reality_server="$(node_value "$tag" "reality_server")"
    jq -n \
      --arg tag "$tag" \
      --arg name "$name" \
      --arg uuid "$uuid" \
      --arg server "$reality_server" \
      --arg private_key "$(secret_value "$tag" "private_key")" \
      --arg short_id "$(node_value "$tag" "short_id")" \
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
    uuid="$(secret_value "$tag" "uuid")"
    ws_path="$(node_value "$tag" "ws_path")"
    cert_file="$(node_value "$tag" "certificate_path")"
    key_file="$(node_value "$tag" "key_path")"
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
    password="$(secret_value "$tag" "password")"
    cert_file="$(node_value "$tag" "certificate_path")"
    key_file="$(node_value "$tag" "key_path")"
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
    uuid="$(secret_value "$tag" "uuid")"
    ws_path="$(node_value "$tag" "ws_path")"
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
    uuid="$(secret_value "$tag" "uuid")"
    password="$(secret_value "$tag" "password")"
    cert_file="$(node_value "$tag" "certificate_path")"
    key_file="$(node_value "$tag" "key_path")"
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
    password="$(secret_value "$tag" "password")"
    cert_file="$(node_value "$tag" "certificate_path")"
    key_file="$(node_value "$tag" "key_path")"
    local up_mbps down_mbps bbr_profile
    up_mbps="$(node_value "$tag" "up_mbps")"
    down_mbps="$(node_value "$tag" "down_mbps")"
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
      --arg username "$(node_value "$tag" "username")" \
      --arg password "$(secret_value "$tag" "password")" \
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

stop_argo_node() {
  local tag="$1"
  kill_pid_file "${BASE_DIR}/runtime/${tag}.pid" "${CLOUDFLARED_BIN}"
}

start_argo_node() {
  local tag="$1"
  local mode port token log_file pid_file domain edge_ip

  [ -x "${CLOUDFLARED_BIN}" ] || install_cloudflared_bin
  mode="$(node_value "$tag" "argo_mode")"
  port="$(node_value "$tag" "port")"
  log_file="${BASE_DIR}/logs/${tag}.cloudflared.log"
  pid_file="${BASE_DIR}/runtime/${tag}.pid"

  stop_argo_node "$tag"
  : >"${log_file}"
  chmod 600 "${log_file}"

  # token 模式的 endpoint_domain 是安装时提供的不变值：不得清空，
  # 否则每次服务重启后固定隧道链接会显示"尚未分配"（v0.2.18 回归）
  if [ "${mode}" != "token" ]; then
    # 启动前清空旧域名：临时隧道失败时分享链接不再显示失效地址
    json_set_field "${NODES_FILE}" "${tag}" "endpoint_domain" "" 2>/dev/null || true
  fi

  edge_ip="$(argo_edge_ip_version)"

  if [ "${mode}" = "token" ]; then
    token="$(secret_value "$tag" "argo_token")"
    # token 经环境变量传入，避免明文出现在进程命令行（ps 可见）
    # --protocol http2：压掉 QUIC 内存尖峰（30-50MB → 25-40MB），小内存机更稳
    TUNNEL_TOKEN="${token}" nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --protocol http2 --edge-ip-version "${edge_ip}" run \
      >>"${log_file}" 2>&1 &
    write_pid_file "${pid_file}" "$!"
    return 0
  fi

  nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --protocol http2 --edge-ip-version "${edge_ip}" --url "http://127.0.0.1:${port}" \
    >>"${log_file}" 2>&1 &
  write_pid_file "${pid_file}" "$!"

  # 等待域名出现且确认公共 DNS 已发布（DoH 核验，防"看似成功实则不可解析"）
  if domain="$(wait_for_trycloudflare_domain_verified "${log_file}" 60 1)"; then
    if ! json_set_field "${NODES_FILE}" "${tag}" "endpoint_domain" "${domain}"; then
      cleanup_argo_pid "${pid_file}"
      return 1
    fi
  else
    cleanup_argo_pid "${pid_file}"
    json_set_field "${NODES_FILE}" "${tag}" "endpoint_domain" "" 2>/dev/null || true
    print_err "等待 ${tag} 的临时 Argo 域名超时（含 DNS 发布确认）。"
    return 1
  fi
}

restart_all_argo_nodes() {
  local tag
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    if [ "$(node_value "$tag" "protocol")" = "vless-argo" ]; then
      # 单个隧道启动失败不影响其余隧道与调用方
      start_argo_node "$tag" || print_warn "Argo 隧道 ${tag} 启动失败。"
    fi
  done < <(iter_node_tags)
}

add_vless_reality() {
  local tag port name uuid reality_server key_output private_key public_key short_id node_json secret_json
  ensure_singbox_ready
  acquire_lock
  tag="$(generate_tag "vless-reality")"
  port="$(prompt_port 443)"
  name="$(prompt_with_default "节点名称" "VLESS-Reality")"
  uuid="$(prompt_optional_value "UUID（留空自动生成）")"
  uuid="${uuid:-$(generate_uuid)}"
  reality_server="$(prompt_safe_domain "Reality 域名" "${DEFAULT_REALITY_SERVER}")"

  key_output="$("${SINGBOX_BIN}" generate reality-keypair)"
  private_key="$(printf '%s\n' "$key_output" | sed -n 's/^PrivateKey:[[:space:]]*//p' | head -n 1)"
  public_key="$(printf '%s\n' "$key_output" | sed -n 's/^PublicKey:[[:space:]]*//p' | head -n 1)"
  [ -n "$private_key" ] || fatal "无法解析 Reality 私钥。"
  [ -n "$public_key" ] || fatal "无法解析 Reality 公钥。"
  short_id="$(generate_hex 4)"

  node_json="$(jq -n \
    --arg protocol "vless-reality" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg reality_server "$reality_server" \
    --arg public_key "$public_key" \
    --arg short_id "$short_id" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      reality_server: $reality_server,
      public_key: $public_key,
      short_id: $short_id
    }')"

  secret_json="$(jq -n \
    --arg uuid "$uuid" \
    --arg private_key "$private_key" '{ uuid: $uuid, private_key: $private_key }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! start_service; then
    rollback_new_node "$tag"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_vless_ws_tls() {
  local tag port name uuid preferred_domain host_domain ws_path cert_bundle cert_mode cert_file key_file node_json secret_json
  ensure_singbox_ready
  acquire_lock
  tag="$(generate_tag "vless-ws-tls")"
  port="$(prompt_port 8443)"
  name="$(prompt_with_default "节点名称" "VLESS-WS-TLS")"
  uuid="$(prompt_optional_value "UUID（留空自动生成）")"
  uuid="${uuid:-$(generate_uuid)}"
  preferred_domain="$(prompt_cdn_domain)"
  host_domain="$(prompt_safe_domain "Host/SNI 域名" "${DEFAULT_TLS_SERVER}")"
  ws_path="$(prompt_with_default "WebSocket 路径" "$(random_ws_path)")"
  cert_bundle="$(prompt_certificate_bundle "$tag" "$host_domain")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "vless-ws-tls" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg preferred_domain "$preferred_domain" \
    --arg host_domain "$host_domain" \
    --arg ws_path "$ws_path" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      preferred_domain: $preferred_domain,
      host_domain: $host_domain,
      ws_path: $ws_path,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  secret_json="$(jq -n --arg uuid "$uuid" '{ uuid: $uuid }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! start_service; then
    rollback_new_node "$tag" "$cert_file" "$key_file"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_anytls() {
  local tag port name password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json
  ensure_singbox_ready
  acquire_lock
  tag="$(generate_tag "anytls")"
  port="$(prompt_port 5443)"
  name="$(prompt_with_default "节点名称" "AnyTLS")"
  password="$(prompt_optional_value "密码（留空自动生成）")"
  password="${password:-$(generate_hex 8)}"
  tls_server="$(prompt_safe_domain "SNI 域名" "${DEFAULT_TLS_SERVER}")"
  cert_bundle="$(prompt_certificate_bundle "$tag" "$tls_server")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "anytls" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg tls_server "$tls_server" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      tls_server: $tls_server,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! start_service; then
    rollback_new_node "$tag" "$cert_file" "$key_file"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_vless_argo() {
  local tag port name uuid preferred_domain ws_path argo_mode argo_token endpoint_domain node_json secret_json
  ensure_singbox_ready
  acquire_lock
  tag="$(generate_tag "vless-argo")"
  port="$(prompt_port 8001)"
  name="$(prompt_with_default "节点名称" "VLESS-Argo")"
  uuid="$(prompt_optional_value "UUID（留空自动生成）")"
  uuid="${uuid:-$(generate_uuid)}"
  preferred_domain="$(prompt_cdn_domain)"
  ws_path="$(prompt_with_default "WebSocket 路径" "$(random_ws_path)")"
  argo_mode="$(prompt_choice "隧道模式 (temp/token)" "temp")"
  if [ "${argo_mode}" = "token" ]; then
    argo_token="$(prompt_nonempty "Cloudflared 隧道 Token")"
    endpoint_domain="$(prompt_nonempty "Argo 回源域名")"
    if ! is_safe_domain "${endpoint_domain}"; then
      print_warn "回源域名格式无效：${endpoint_domain}，已回退临时隧道。"
      argo_mode="temp"
      argo_token=""
      endpoint_domain=""
    fi
  else
    argo_mode="temp"
    argo_token=""
    endpoint_domain=""
  fi

  node_json="$(jq -n \
    --arg protocol "vless-argo" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg preferred_domain "$preferred_domain" \
    --arg ws_path "$ws_path" \
    --arg argo_mode "$argo_mode" \
    --arg endpoint_domain "$endpoint_domain" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      preferred_domain: $preferred_domain,
      ws_path: $ws_path,
      argo_mode: $argo_mode,
      endpoint_domain: $endpoint_domain
    }')"

  secret_json="$(jq -n \
    --arg uuid "$uuid" \
    --arg argo_token "$argo_token" '{ uuid: $uuid, argo_token: $argo_token }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! start_service || ! start_argo_node "$tag"; then
    rollback_new_node "$tag"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_tuic_v5() {
  local tag port name uuid password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json
  ensure_singbox_ready
  acquire_lock
  tag="$(generate_tag "tuic-v5")"
  port="$(prompt_port 10443)"
  name="$(prompt_with_default "节点名称" "TUIC-v5")"
  uuid="$(prompt_optional_value "UUID（留空自动生成）")"
  uuid="${uuid:-$(generate_uuid)}"
  password="$(prompt_optional_value "密码（留空自动生成）")"
  password="${password:-$uuid}"
  tls_server="$(prompt_safe_domain "SNI 域名" "${DEFAULT_TLS_SERVER}")"
  cert_bundle="$(prompt_certificate_bundle "$tag" "$tls_server")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "tuic-v5" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg tls_server "$tls_server" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      tls_server: $tls_server,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  secret_json="$(jq -n --arg uuid "$uuid" --arg password "$password" '{ uuid: $uuid, password: $password }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! start_service; then
    rollback_new_node "$tag" "$cert_file" "$key_file"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_hy2() {
  local tag port name password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json up_mbps down_mbps
  ensure_singbox_ready
  acquire_lock
  tag="$(generate_tag "hy2")"
  port="$(prompt_port 11443)"
  name="$(prompt_with_default "节点名称" "Hysteria2")"
  password="$(prompt_optional_value "密码（留空自动生成）")"
  password="${password:-$(generate_hex 8)}"
  tls_server="$(prompt_safe_domain "SNI 域名" "${DEFAULT_TLS_SERVER}")"
  up_mbps="$(prompt_optional_value "上行带宽 Mbps（留空=默认 200）")"
  up_mbps="${up_mbps:-200}"
  down_mbps="$(prompt_optional_value "下行带宽 Mbps（留空=默认 200）")"
  down_mbps="${down_mbps:-200}"
  cert_bundle="$(prompt_certificate_bundle "$tag" "$tls_server")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "hy2" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg tls_server "$tls_server" \
    --argjson up_mbps "${up_mbps:-0}" \
    --argjson down_mbps "${down_mbps:-0}" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      tls_server: $tls_server,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }
    + (if ($up_mbps > 0) then { up_mbps: $up_mbps } else {} end)
    + (if ($down_mbps > 0) then { down_mbps: $down_mbps } else {} end)')"

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! start_service; then
    rollback_new_node "$tag" "$cert_file" "$key_file"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_socks5() {
  local tag port name username password node_json secret_json
  ensure_singbox_ready
  acquire_lock
  tag="$(generate_tag "socks5")"
  port="$(prompt_port 1080)"
  name="$(prompt_with_default "节点名称" "SOCKS5")"
  username="$(prompt_with_default "用户名" "user")"
  password="$(prompt_optional_value "密码（留空自动生成）")"
  password="${password:-$(generate_hex 6)}"

  node_json="$(jq -n \
    --arg protocol "socks5" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg username "$username" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      username: $username
    }')"

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! start_service; then
    rollback_new_node "$tag"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

# ---------------------------------------------------------------------------
# 环境变量一键安装（rep / ins），配合网页命令生成器使用
# 端口启用协议: vlrt=VLESS-Reality wspt=VLESS-WS-TLS tupt=TUIC anypt=AnyTLS
#               hypt=Hysteria2 socks5pt=SOCKS5 argo=vlpt 启用 VLESS-Argo
# ---------------------------------------------------------------------------

# 注意：局部变量统一加 __env_ 前缀，避免与用户环境变量同名，
# 否则 ${!key} 间接引用会命中局部变量（bash 动态作用域）导致取值错误。
env_var() {
  local __env_key="$1"
  local __env_value="${!__env_key:-}"
  printf '%s' "$(normalize_input "${__env_value}")"
}

env_port() {
  local __env_key="$1"
  local __env_value
  __env_value="$(env_var "$__env_key")"
  if [ -z "$__env_value" ]; then
    return 1
  fi
  if ! [[ "$__env_value" =~ ^[0-9]+$ ]] || [ "$__env_value" -lt 1 ] || [ "$__env_value" -gt 65535 ]; then
    print_warn "环境变量 ${__env_key} 不是有效端口（1-65535）：${__env_value}，已忽略。"
    return 1
  fi
  printf '%s' "$__env_value"
}

auto_has_node_env() {
  local v
  for v in vlrt wspt tupt anypt hypt socks5pt argo; do
    if [ -n "$(env_var "$v")" ]; then
      return 0
    fi
  done
  return 1
}

# 预校验：把环境变量解析为 "协议 端口" 行。
# 端口设置了但非法时返回 1——必须在清空任何数据之前发生（rep 安全前提）。
auto_collect_specs() {
  local entry var proto raw port
  for entry in vlrt:vless-reality wspt:vless-ws-tls tupt:tuic-v5 anypt:anytls hypt:hy2 socks5pt:socks5; do
    var="${entry%%:*}"
    proto="${entry##*:}"
    raw="$(env_var "$var")"
    [ -n "${raw}" ] || continue
    if ! port="$(env_port "$var")"; then
      print_err "环境变量 ${var}=${raw} 不是有效端口。"
      return 1
    fi
    printf '%s %s\n' "${proto}" "${port}"
  done
  if auto_argo_requested; then
    raw="$(env_var "argo_pt")"
    if [ -z "${raw}" ]; then
      port=8001
    elif ! port="$(env_port "argo_pt")"; then
      print_err "环境变量 argo_pt=${raw} 不是有效端口。"
      return 1
    fi
    printf '%s %s\n' "vless-argo" "${port}"
  fi
  return 0
}

auto_cert_bundle() {
  local tag="$1"
  local domain="$2"
  # 局部变量统一 __ 前缀：cert_path/key_path/cert_b64/key_b64 是环境变量键名，
  # 若声明同名局部变量，env_var 的间接引用会命中空的局部变量（bash 动态作用域）
  local __mode __cert_path __key_path __cert_b64 __key_b64 __pair

  __mode="$(env_var "cert")"
  __mode="${__mode:-self}"
  if [ "${__mode}" = "custom" ]; then
    # v1.2.5 优先接口粘贴的 PEM 内容（base64），无内容时回退文件路径方式
    __cert_b64="$(env_var "cert_b64")"
    __key_b64="$(env_var "key_b64")"
    if [ -n "$__cert_b64" ] || [ -n "$__key_b64" ]; then
      if [ -n "$__cert_b64" ] && [ -n "$__key_b64" ] && __pair="$(import_custom_certificate_content "$tag" "$__cert_b64" "$__key_b64")"; then
        printf 'custom|%s|%s' "${__pair%|*}" "${__pair#*|}"
        return 0
      fi
      print_warn "cert_b64/key_b64 解码失败（无效的 base64 或缺少其一），节点 ${tag} 回退自签证书。"
      __pair="$(ensure_tls_material "$tag" "$domain")"
      printf 'self-signed|%s|%s' "${__pair%|*}" "${__pair#*|}"
      return 0
    fi
    __cert_path="$(env_var "cert_path")"
    __key_path="$(env_var "key_path")"
    if [ -n "$__cert_path" ] && [ -n "$__key_path" ] && __pair="$(import_custom_certificate_bundle "$tag" "$__cert_path" "$__key_path")"; then
      printf 'custom|%s|%s' "${__pair%|*}" "${__pair#*|}"
      return 0
    fi
    print_warn "自定义证书不可用（缺少 cert_path/key_path 或读取失败），节点 ${tag} 回退自签证书。"
  elif [ "${__mode}" != "self" ] && [ "${__mode}" != "self-signed" ]; then
    print_warn "未知证书模式 cert=${__mode}，节点 ${tag} 使用自签证书。"
  fi
  __pair="$(ensure_tls_material "$tag" "$domain")"
  printf 'self-signed|%s|%s' "${__pair%|*}" "${__pair#*|}"
}

auto_save_node() {
  local tag="$1"
  local node_json="$2"
  local secret_json="$3"
  save_node_bundle "$tag" "$node_json" "$secret_json"
}

auto_add_vless_reality() {
  local port="$1"
  local tag name uuid reality_server key_output private_key public_key short_id node_json secret_json
  tag="$(generate_tag "vless-reality")"
  if [ -n "${ENV_NAME}" ]; then name="${ENV_NAME}-Reality"; else name="VLESS-Reality"; fi
  uuid="${ENV_UUID:-$(generate_uuid)}"
  reality_server="${ENV_VL_SNI:-${DEFAULT_REALITY_SERVER}}"

  if ! key_output="$("${SINGBOX_BIN}" generate reality-keypair)"; then
    print_err "生成 Reality 密钥对失败，跳过 vlrt 节点。"
    return 1
  fi
  private_key="$(printf '%s\n' "$key_output" | sed -n 's/^PrivateKey:[[:space:]]*//p' | head -n 1)"
  public_key="$(printf '%s\n' "$key_output" | sed -n 's/^PublicKey:[[:space:]]*//p' | head -n 1)"
  if [ -z "$private_key" ] || [ -z "$public_key" ]; then
    print_err "无法解析 Reality 密钥对，跳过 vlrt 节点。"
    return 1
  fi
  short_id="$(generate_hex 4)"

  node_json="$(jq -n \
    --arg protocol "vless-reality" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg reality_server "$reality_server" \
    --arg public_key "$public_key" \
    --arg short_id "$short_id" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      reality_server: $reality_server,
      public_key: $public_key,
      short_id: $short_id
    }')"

  secret_json="$(jq -n \
    --arg uuid "$uuid" \
    --arg private_key "$private_key" '{ uuid: $uuid, private_key: $private_key }')"

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 端口: ${port}"
}

auto_add_vless_ws_tls() {
  local port="$1"
  local tag name uuid preferred_domain host_domain ws_path cert_bundle cert_mode cert_file key_file node_json secret_json ws_mode cdn_port cdn_sni
  tag="$(generate_tag "vless-ws-tls")"
  if [ -n "${ENV_NAME}" ]; then name="${ENV_NAME}-WS-TLS"; else name="VLESS-WS-TLS"; fi
  uuid="${ENV_UUID:-$(generate_uuid)}"
  # CDN 连接地址（ws_cdn 设计：脚本专用 > 共享 > 兼容旧名 cdn_host > 内置默认）
  preferred_domain="${ENV_WS_CDN_VLESS_CF_HOST:-${ENV_WS_CDN_CF_HOST:-${ENV_CDN_HOST:-${DEFAULT_CDN_DOMAIN}}}}"
  host_domain="${ENV_WS_HOST:-${DEFAULT_TLS_SERVER}}"
  ws_path="${ENV_WS_PATH:-$(random_ws_path)}"
  ws_mode="${ENV_WS_MODE:-direct}"
  # CDN 端口：脚本专用 > 共享 > 兼容旧名 cdn_port > 443
  cdn_port="${ENV_WS_CDN_VLESS_CF_PT:-${ENV_WS_CDN_CF_PT:-${ENV_CDN_PORT:-443}}}"
  # CDN 回源域名/SNI（仅 cdn 模式使用）：脚本专用 > 共享 > 内置默认（= 连接地址，与 jyucoeng 语义一致）
  cdn_sni="${ENV_WS_CDN_VLESS_SNI:-${ENV_WS_CDN_SNI:-${preferred_domain}}}"
  case "${ws_mode}" in
  direct | cdn) ;;
  *)
    print_warn "ws_mode=${ws_mode} 非法，回退 direct（可选值：direct|c_dn）。"
    ws_mode="direct"
    ;;
  esac
  if [[ ! "${cdn_port}" =~ ^[0-9]+$ ]] || [ "${cdn_port}" -lt 1 ] || [ "${cdn_port}" -gt 65535 ]; then
    print_warn "cdn_port=${cdn_port} 非法，回退 443。"
    cdn_port=443
  fi
  cert_bundle="$(auto_cert_bundle "$tag" "$host_domain")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "vless-ws-tls" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg preferred_domain "$preferred_domain" \
    --arg host_domain "$host_domain" \
    --arg ws_path "$ws_path" \
    --arg ws_mode "$ws_mode" \
    --argjson cdn_port "$cdn_port" \
    --arg cdn_sni "$cdn_sni" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      preferred_domain: $preferred_domain,
      host_domain: $host_domain,
      ws_path: $ws_path,
      ws_mode: $ws_mode,
      cdn_port: $cdn_port,
      cdn_sni: $cdn_sni,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  secret_json="$(jq -n --arg uuid "$uuid" '{ uuid: $uuid }')"

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 端口: ${port}"
}

auto_add_anytls() {
  local port="$1"
  local tag name password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json
  tag="$(generate_tag "anytls")"
  if [ -n "${ENV_NAME}" ]; then name="${ENV_NAME}-AnyTLS"; else name="AnyTLS"; fi
  password="${ENV_PASSWD:-$(generate_hex 8)}"
  tls_server="${ENV_ANY_SNI:-${DEFAULT_TLS_SERVER}}"
  cert_bundle="$(auto_cert_bundle "$tag" "$tls_server")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "anytls" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg tls_server "$tls_server" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      tls_server: $tls_server,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')"

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 端口: ${port}"
}

auto_argo_requested() {
  local v
  v="$(env_var "argo")"
  case "${v,,}" in
  vlpt | vless | true | 1 | yes) return 0 ;;
  *) return 1 ;;
  esac
}

auto_add_vless_argo() {
  local port="$1"
  local tag name uuid preferred_domain cdn_port ws_path argo_mode argo_token endpoint_domain node_json secret_json
  tag="$(generate_tag "vless-argo")"
  if [ -n "${ENV_NAME:-}" ]; then name="${ENV_NAME}-Argo"; else name="VLESS-Argo"; fi
  uuid="${ENV_UUID:-$(generate_uuid)}"
  # Argo 专属优选域名/端口（v0.3.3）：独立于 WS-CDN，缺省回退 cdn_host/443
  preferred_domain="${ENV_ARGO_CDN_HOST:-${ENV_CDN_HOST:-${DEFAULT_CDN_DOMAIN}}}"
  cdn_port="${ENV_ARGO_CDN_PORT:-443}"
  if [[ ! "${cdn_port}" =~ ^[0-9]+$ ]] || [ "${cdn_port}" -lt 1 ] || [ "${cdn_port}" -gt 65535 ]; then
    print_warn "argo_cdn_port=${cdn_port} 非法，回退 443。"
    cdn_port=443
  fi
  ws_path="${ENV_WS_PATH:-$(random_ws_path)}"
  argo_token="$(env_var "agk")"
  endpoint_domain="$(env_var "agn")"
  if [ -n "$argo_token" ] && [ -n "$endpoint_domain" ]; then
    argo_mode="token"
  else
    if [ -n "$argo_token" ] || [ -n "$endpoint_domain" ]; then
      print_warn "Argo 固定隧道需要同时提供 agn（域名）和 agk（Token），已回退临时隧道。"
    fi
    argo_mode="temp"
    argo_token=""
    endpoint_domain=""
  fi

  node_json="$(jq -n \
    --arg protocol "vless-argo" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg preferred_domain "$preferred_domain" \
    --argjson cdn_port "$cdn_port" \
    --arg ws_path "$ws_path" \
    --arg argo_mode "$argo_mode" \
    --arg endpoint_domain "$endpoint_domain" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      preferred_domain: $preferred_domain,
      cdn_port: $cdn_port,
      ws_path: $ws_path,
      argo_mode: $argo_mode,
      endpoint_domain: $endpoint_domain
    }')"

  secret_json="$(jq -n \
    --arg uuid "$uuid" \
    --arg argo_token "$argo_token" '{ uuid: $uuid, argo_token: $argo_token }')"

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 本地端口: ${port} | 模式: ${argo_mode}"
}

auto_add_tuic_v5() {
  local port="$1"
  local tag name uuid password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json
  tag="$(generate_tag "tuic-v5")"
  if [ -n "${ENV_NAME}" ]; then name="${ENV_NAME}-TUIC"; else name="TUIC-v5"; fi
  uuid="${ENV_UUID:-$(generate_uuid)}"
  password="${ENV_PASSWD:-$uuid}"
  tls_server="${ENV_TU_SNI:-${DEFAULT_TLS_SERVER}}"
  cert_bundle="$(auto_cert_bundle "$tag" "$tls_server")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "tuic-v5" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg tls_server "$tls_server" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      tls_server: $tls_server,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  secret_json="$(jq -n --arg uuid "$uuid" --arg password "$password" '{ uuid: $uuid, password: $password }')"

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 端口: ${port}"
}

auto_positive_or_default() {
  local __env_key="$1"
  local __env_default="$2"
  local __env_value
  __env_value="$(env_var "$__env_key")"
  if [[ "$__env_value" =~ ^[0-9]+$ ]] && [ "$__env_value" -gt 0 ]; then
    printf '%s' "$__env_value"
  else
    printf '%s' "$__env_default"
  fi
}

auto_add_hy2() {
  local port="$1"
  local tag name password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json
  local __hy_up __hy_down
  tag="$(generate_tag "hy2")"
  if [ -n "${ENV_NAME}" ]; then name="${ENV_NAME}-HY2"; else name="Hysteria2"; fi
  password="${ENV_PASSWD:-$(generate_hex 8)}"
  tls_server="${ENV_HY_SNI:-${DEFAULT_TLS_SERVER}}"
  # 局部名不用 up_mbps/down_mbps，避免遮蔽同名用户环境变量导致读取为空
  # 默认 200 Mbps（未显式设置时）；只填其一则另一个独立成单方向限速
  __hy_up="$(env_var "up_mbps")"
  __hy_down="$(env_var "down_mbps")"
  __hy_up="${__hy_up:-200}"
  __hy_down="${__hy_down:-200}"
  case "${__hy_up}" in
  *[!0-9]* | "") __hy_up="200" ;;
  esac
  case "${__hy_down}" in
  *[!0-9]* | "") __hy_down="200" ;;
  esac
  cert_bundle="$(auto_cert_bundle "$tag" "$tls_server")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "hy2" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg tls_server "$tls_server" \
    --argjson up_mbps "$__hy_up" \
    --argjson down_mbps "$__hy_down" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      tls_server: $tls_server,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }
    + (if ($up_mbps > 0) then { up_mbps: $up_mbps } else {} end)
    + (if ($down_mbps > 0) then { down_mbps: $down_mbps } else {} end)')"

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')"

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 端口: ${port}"
}

auto_add_socks5() {
  local port="$1"
  local tag name username password node_json secret_json
  tag="$(generate_tag "socks5")"
  if [ -n "${ENV_NAME}" ]; then name="${ENV_NAME}-SOCKS5"; else name="SOCKS5"; fi
  username="${ENV_SOCKS5_USER:-user}"
  password="${ENV_SOCKS5_PASS:-$(generate_hex 6)}"

  node_json="$(jq -n \
    --arg protocol "socks5" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg username "$username" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      username: $username
    }')"

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')"

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 端口: ${port}"
}

wipe_records() {
  local tmp
  tmp="$(mktemp "${BASE_DIR}/.nodes.XXXXXX")"
  printf '{}\n' >"${tmp}" && chmod 600 "${tmp}" && mv "${tmp}" "${NODES_FILE}"
  tmp="$(mktemp "${BASE_DIR}/.secrets.XXXXXX")"
  printf '{}\n' >"${tmp}" && chmod 600 "${tmp}" && mv "${tmp}" "${SECRETS_FILE}"
}

delete_all_nodes() {
  local tag cert_file key_file
  init_storage
  acquire_lock
  backup_state >/dev/null
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    stop_argo_node "${tag}"
    cert_file="$(node_value "${tag}" "certificate_path")"
    key_file="$(node_value "${tag}" "key_path")"
    remove_node_certificates "${tag}" "${cert_file}" "${key_file}"
  done < <(iter_node_tags)
  wipe_records
  render_config
  start_service
  sanitize_permissions
  release_lock
  print_ok "已删除全部节点（含证书）并重启服务。"
}

auto_try_port() {
  local port="$1"
  local label="$2"
  if ! port_available "$port"; then
    print_warn "端口 ${port} 已被占用，跳过 ${label} 节点。"
    return 1
  fi
  return 0
}

# 清理不再被任何节点引用的证书/私钥文件（tag 命名不含点，取首个 . 前缀即 tag）
cleanup_orphan_certs() {
  local f path tag
  while IFS= read -r f; do
    path="${f##*/}"
    tag="${path%%.*}"
    [ -n "${tag}" ] || continue
    if ! jq -e --arg tag "${tag}" 'has($tag)' "${NODES_FILE}" >/dev/null 2>&1; then
      rm -f "${f}"
    fi
  done < <(find "${CERT_DIR}" -type f \( -name '*.crt' -o -name '*.key' \) 2>/dev/null)
}

auto_install() {
  local action="$1"
  local tag port spec line backup_dir
  local added=0 failed=0
  local -a specs=()
  local ENV_NAME ENV_UUID ENV_PASSWD
  local ENV_VL_SNI ENV_TU_SNI ENV_ANY_SNI ENV_HY_SNI ENV_WS_HOST ENV_WS_PATH ENV_CDN_HOST
  local ENV_SOCKS5_USER ENV_SOCKS5_PASS

  detect_systemd
  init_storage

  if ! auto_has_node_env; then
    print_err "未检测到任何节点环境变量（vlrt / wspt / tupt / anypt / hypt / socks5pt / argo），放弃安装。"
    print_info "示例：vlrt=2083 hypt=2082 name='HK' sbm ${action}"
    exit 1
  fi

  # 预校验：端口非法在这里直接失败，任何已有数据都不会被改动
  if ! spec="$(auto_collect_specs)"; then
    print_err "输入校验失败，未更改任何数据。"
    exit 1
  fi
  while IFS= read -r line; do
    [ -n "${line}" ] && specs+=("${line}")
  done <<<"${spec}"
  if [ "${#specs[@]}" -eq 0 ]; then
    print_err "未检测到有效的节点端口环境变量，放弃安装。"
    exit 1
  fi

  ensure_singbox_ready
  acquire_lock

  # 破坏性操作前先快照；rep 失败时据此恢复
  backup_dir="$(backup_state)"

  if [ "${action}" = "rep" ]; then
    while IFS= read -r tag; do
      [ -n "${tag}" ] || continue
      stop_argo_node "${tag}"
    done < <(iter_node_tags)
    stop_service || true
    wipe_records
    # 标记 rep 事务窗口：此后任何失败（render/check/start/证书迁移）都会触发
    # handle_common_error 自动恢复该备份，禁止停留"旧节点消失、新配置未启动"状态（F-02）
    # shellcheck disable=SC2034  # 在 lib/common.sh 的 ERR 陷阱中读取
    _AUTO_ROLLBACK_DIR="${backup_dir}"
    print_info "已清空原有节点（备份：${backup_dir}），按环境变量重建。"
  else
    print_info "已备份现有状态：${backup_dir}"
  fi

  ENV_NAME="$(env_var "name")"
  ENV_UUID="$(env_var "uuid")"
  ENV_PASSWD="$(env_var "passwd")"
  # 域名类环境变量经白名单校验，非法值回退内置默认
  ENV_VL_SNI="$(env_domain_or_default "vl_sni" "${DEFAULT_REALITY_SERVER}")"
  ENV_TU_SNI="$(env_domain_or_default "tu_sni" "${DEFAULT_TLS_SERVER}")"
  ENV_ANY_SNI="$(env_domain_or_default "any_sni" "${DEFAULT_TLS_SERVER}")"
  ENV_HY_SNI="$(env_domain_or_default "hy_sni" "${DEFAULT_TLS_SERVER}")"
  ENV_WS_HOST="$(env_domain_or_default "ws_host" "${DEFAULT_TLS_SERVER}")"
  ENV_WS_PATH="$(env_var "ws_path")"
  ENV_WS_MODE="$(env_var "ws_mode")"
  ENV_CDN_PORT="$(env_var "cdn_port")"
  ENV_CDN_HOST="$(env_domain_or_default "cdn_host" "${DEFAULT_CDN_DOMAIN}")"
  # Argo 专属优选域名/端口（v0.3.3）：与 WS-CDN 独立设置，缺省回退 cdn_host/443
  ENV_ARGO_CDN_HOST="$(env_domain_or_default "argo_cdn_host" "${ENV_CDN_HOST}")"
  ENV_ARGO_CDN_PORT="$(env_var "argo_cdn_port")"
  # ws_cdn 设计（v0.3.0）：脚本专用前缀优先，共享前缀次之，兼容旧名 cdn_host/ws_host/cdn_port 兜底。
  # 域名类变量经白名单校验，空值留给调用方回退链处理。
  ENV_WS_CDN_CF_HOST="$(env_domain_or_default "ws_cdn_cf_host" "")"
  ENV_WS_CDN_CF_PT="$(env_var "ws_cdn_cf_pt")"
  ENV_WS_CDN_SNI="$(env_domain_or_default "ws_cdn_sni" "")"
  ENV_WS_CDN_VLESS_CF_HOST="$(env_domain_or_default "ws_cdn_vless_cf_host" "")"
  ENV_WS_CDN_VLESS_CF_PT="$(env_var "ws_cdn_vless_cf_pt")"
  ENV_WS_CDN_VLESS_SNI="$(env_domain_or_default "ws_cdn_vless_sni" "")"
  # v1.2.4：CDN 采 CF 证书方案（Full/Full-Strict 回源），源站仅一个 TLS WS inbound（wspt），
  # 不再生成明文 HTTP 回源 inbound；ws_cdn_origin_port 已废弃。证书方式支持
  # cert=custom（如 Cloudflare Origin CA 证书）+ cert_path/key_path，自签默认适用于 Full 模式。
  # 默认优选域名仅在 ws_mode=cdn（CDN 中转）时要求本机已接入前置 CDN；直连模式（默认）不依赖 cdn_host
  if [ "${ENV_CDN_HOST}" = "${DEFAULT_CDN_DOMAIN}" ] && [ "${ENV_WS_MODE:-direct}" = "cdn" ] && [ "${confirm_default_cdn:-}" != "1" ]; then
    print_warn "⚠️ 未设置有效 cdn_host：WS-TLS(CDN 中转) 节点将使用内置优选域名 ${DEFAULT_CDN_DOMAIN}（仅该域名已接入本机前置 CDN 时可达）。"
    print_warn "   请改用 cdn_host=你的优选域名或IP 重新执行；确认使用默认值可加 confirm_default_cdn=1 消除本提示。"
  fi
  ENV_SOCKS5_USER="$(env_var "socks5_username")"
  ENV_SOCKS5_PASS="$(env_var "socks5_password")"

  # P5/S3：持久化性能与调优参数（go_gc / net_tune / 内存上限），使 rep、重启、
  # watchdog 等后续流程在无 install 环境变量时也能读取同一套全局配置。
  local _key _val
  for _key in go_gc net_tune mem_high_mb mem_max_mb; do
    _val="$(env_var "$_key")"
    if [ -n "${_val}" ]; then
      set_setting "$_key" "$_val"
    fi
  done

  for line in "${specs[@]}"; do
    port="${line##* }"
    case "${line%% *}" in
    vless-reality)
      if auto_try_port "$port" "VLESS-Reality"; then
        auto_add_vless_reality "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    vless-ws-tls)
      if auto_try_port "$port" "VLESS-WS-TLS"; then
        auto_add_vless_ws_tls "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    anytls)
      if auto_try_port "$port" "AnyTLS"; then
        auto_add_anytls "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    vless-argo)
      if auto_try_port "$port" "VLESS-Argo"; then
        auto_add_vless_argo "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    tuic-v5)
      if auto_try_port "$port" "TUIC-v5"; then
        auto_add_tuic_v5 "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    hy2)
      if auto_try_port "$port" "Hysteria2"; then
        auto_add_hy2 "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    socks5)
      if auto_try_port "$port" "SOCKS5"; then
        auto_add_socks5 "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    esac
  done

  if [ "${added}" -eq 0 ]; then
    _AUTO_ROLLBACK_DIR=""
    if [ "${action}" = "rep" ]; then
      restore_latest_backup || true
      reconcile_state || true
      render_config || true
      start_service || true
      print_err "没有成功写入任何节点（added=0, failed=${failed}），已恢复安装前的节点状态。"
    else
      print_err "没有成功写入任何节点（added=0, failed=${failed}），现有节点未受影响。"
    fi
    release_lock
    exit 1
  fi

  if [ "${action}" = "rep" ]; then
    cleanup_orphan_certs
  fi
  render_config
  start_service
  # 事务已提交：清除回滚标记，此后失败不再触发整事务回滚
  _AUTO_ROLLBACK_DIR=""
  # 隧道启动失败（如临时域名等待超时）不应判定整次安装失败
  restart_all_argo_nodes || print_warn "部分 Argo 隧道启动失败，稍后可用 sbm list 重查域名。"
  sanitize_permissions
  release_lock

  echo
  print_ok "一键安装完成：新增 ${added} 个节点，失败 ${failed} 个。"
  echo
  print_node_list
  echo
  if [ "${failed}" -gt 0 ]; then
    exit 1
  fi
}

print_node_list() {
  local idx=1
  local tag protocol name port public_ip
  public_ip="$(get_public_ip)"
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    protocol="$(node_value "$tag" "protocol")"
    name="$(node_value "$tag" "name")"
    port="$(node_value "$tag" "port")"
    echo "${idx}. ${name} | ${protocol} | 端口: ${port}"
    echo "   标识: ${tag}"
    echo "   链接: $(build_share_link "$tag" "$public_ip")"
    idx=$((idx + 1))
  done < <(iter_node_tags)

  if [ "${idx}" -eq 1 ]; then
    echo "当前没有节点。"
  fi
}

# 生成 base64 订阅内容（全部节点分享链接逐行 base64，输出到 stdout 或文件）
sub_command() {
  local out_file="${1:-}"
  local links="" tag content public_ip
  init_storage
  public_ip="$(get_public_ip)"
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    links+="$(build_share_link "${tag}" "$public_ip")"$'\n'
  done < <(iter_node_tags)
  if [ -z "${links//[$'\n']/}" ]; then
    print_err "当前没有可输出的节点。"
    return 1
  fi
  content="$(printf '%s' "${links}" | base64 | tr -d '\n')"
  if [ -n "${out_file}" ]; then
    printf '%s\n' "${content}" >"${out_file}"
    chmod 600 "${out_file}" 2>/dev/null || true
    print_ok "订阅已写入：${out_file}（节点数：$(printf '%s' "${links}" | grep -c .)）"
  else
    printf '%s\n' "${content}"
  fi
}

select_node_tag() {
  local -a rows
  local idx input tag protocol name port
  mapfile -t rows < <(jq -r 'to_entries[] | [.key, .value.protocol, .value.name, (.value.port|tostring)] | @tsv' "${NODES_FILE}" 2>/dev/null)
  [ "${#rows[@]}" -gt 0 ] || return 1

  idx=1
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r tag protocol name port <<<"${row}"
    printf '%s\n' "${idx}. ${name} | ${protocol} | 端口: ${port}" >&2
    idx=$((idx + 1))
  done

  read -r -p "请选择节点编号: " input || return 1
  if ! [[ "${input}" =~ ^[0-9]+$ ]] || [ "${input}" -lt 1 ] || [ "${input}" -gt "${#rows[@]}" ]; then
    return 1
  fi

  IFS=$'\t' read -r tag _ <<<"${rows[$((input - 1))]}"
  printf '%s' "${tag}"
}

list_nodes() {
  init_storage
  echo
  print_node_list
  echo
}

delete_node() {
  local tag protocol cert_file key_file
  init_storage
  tag="$(select_node_tag)" || {
    print_warn "没有可选节点，或输入的编号无效。"
    return 0
  }

  protocol="$(node_value "$tag" "protocol")"
  if ! confirm_yes "确认删除节点 ${tag} 吗？"; then
    return 0
  fi

  acquire_lock
  cert_file="$(node_value "$tag" "certificate_path")"
  key_file="$(node_value "$tag" "key_path")"
  if [ "${protocol}" = "vless-argo" ]; then
    stop_argo_node "$tag"
  fi
  delete_node_records "$tag"
  remove_node_certificates "$tag" "$cert_file" "$key_file"
  render_config || true
  start_service || true
  sanitize_permissions
  release_lock
  print_ok "已删除节点：${tag}"
}

show_status() {
  local count installed_version
  init_storage
  detect_systemd
  count="$(jq 'length' "${NODES_FILE}" 2>/dev/null || printf '0')"
  installed_version="${SINGBOX_VERSION#v}"
  if [ -x "${SINGBOX_BIN}" ]; then
    installed_version="$("${SINGBOX_BIN}" version 2>/dev/null | head -n 1 | awk '{print $NF}')"
    installed_version="${installed_version#v}"
    installed_version="${installed_version:-${SINGBOX_VERSION#v}}"
  fi
  echo
  echo "项目名称：${PROJECT_NAME}"
  echo "当前版本：${SCRIPT_VERSION}"
  echo "服务状态：$(service_state)"
  echo "节点数量：${count}"
  if [ "${has_systemd}" = true ]; then
    if systemd_timer_active; then
      echo "守护定时器：active (下次触发已调度)"
    else
      echo "守护定时器：inactive (未调度)"
    fi
  elif [ "${has_openrc}" = true ]; then
    echo "守护方式：OpenRC + cron"
  else
    echo "守护方式：cron"
  fi
  echo "sing-box 版本：${installed_version}"
  echo "cloudflared 版本：$(cloudflared_installed_version)"
  echo
  print_node_list
  echo
}

restart_stack() {
  acquire_lock
  render_config
  start_service
  restart_all_argo_nodes
  sanitize_permissions
  release_lock
}
