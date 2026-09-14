#!/usr/bin/env bash
set -eEuo pipefail

umask 077

build_share_link() {
  local tag="$1"
  local public_ip="${2:-}"
  local protocol name port host uuid password username fp
  local reality_server public_key short_id ws_path preferred_domain endpoint_domain host_domain tls_server cert_mode ws_mode cdn_port cdn_sni ext certificate_path

  # 单次 jq 批量取出全部字段（nodes+secrets），替代逐字段 node_value/secret_value
  # 的多次 jq 进程（每次 sbm list/sub 对每个节点可省十次左右 jq 启动）
  node_meta_array "$tag"
  protocol="${NODE_META[0]}"
  name="${NODE_META[1]}"
  port="${NODE_META[2]}"
  uuid="${NODE_META[3]}"
  password="${NODE_META[4]}"
  public_key="${NODE_META[6]}"
  short_id="${NODE_META[7]}"
  reality_server="${NODE_META[8]}"
  tls_server="${NODE_META[9]}"
  preferred_domain="${NODE_META[10]}"
  host_domain="${NODE_META[11]}"
  ws_path="${NODE_META[12]}"
  ws_mode="${NODE_META[13]}"
  cdn_port="${NODE_META[14]}"
  cdn_sni="${NODE_META[15]}"
  cert_mode="${NODE_META[16]}"
  certificate_path="${NODE_META[17]}"
  endpoint_domain="${NODE_META[19]}"
  username="${NODE_META[24]}"
  # 支持外部一次性传入解析好的公网 IP（第 2 参），便于订阅/列表在一次网络探测后
  # 复用，避免 N 个节点重复探测；未传时回退进程内缓存探测。
  public_ip="${public_ip:-$(get_public_ip)}"
  host="$(wrap_host "$public_ip")"

  case "$protocol" in
  vless-reality)
    # 批量 url_encode：4 个字段一次 jq 子进程（原逐字段 url_encode 每字段一个 jq fork）
    { read -r reality_server; read -r public_key; read -r short_id; read -r name; } <<EOF
$(url_encode_many "${reality_server}" "${public_key}" "${short_id}" "${name}")
EOF
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
      "$uuid" "$host" "$port" "$reality_server" "$public_key" "$short_id" "$name"
    ;;
  vless-ws-tls)
    ws_mode="${ws_mode:-direct}"
    cdn_port="${cdn_port:-443}"
    if [ "${ws_mode}" = "cdn" ]; then
      # CDN 中转模式：客户端连 cdn_host:cdn_port，SNI/Host 走回源域名（cdn_sni，默认同连接地址），
      # 由前置 CDN 根据 SNI/Host 识别并回源到本机。
      if [ -z "${preferred_domain}" ] || [ "${preferred_domain}" = "${DEFAULT_CDN_DOMAIN}" ]; then
        print_warn "WS-TLS 节点 ${tag} 使用默认优选域名 ${DEFAULT_CDN_DOMAIN}：仅当该域名已接入本机前置 CDN 时可用，否则请把 cdn_host 设为你自己的域名或改用 ws_mode=direct 直连。"
      fi
      cdn_sni="${cdn_sni:-${preferred_domain}}"
      # 批量编码 cdn_sni×2 + ws_path + name（原每字段一个 url_encode=1 jq 子进程）
      { read -r cdn_sni_enc; read -r cdn_sni_enc2; read -r ws_path_enc; read -r name_enc; } <<EOF
$(url_encode_many "${cdn_sni}" "${cdn_sni}" "${ws_path}" "${name}")
EOF
      printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s#%s' \
        "$uuid" "$(wrap_host "$preferred_domain")" "$cdn_port" \
        "${cdn_sni_enc}" "${cdn_sni_enc2}" "${ws_path_enc}" "${name_enc}"
    else
      # 直连模式：客户端连服务器 IP + wspt，SNI/Host 均走 WS Host 域名（自签证书跳过校验）
      # 批量编码 host_domain×2（sni+host）+ ws_path + name（一次 jq 子进程）
      { read -r sni_enc; read -r host_enc; read -r ws_path_enc; read -r name_enc; } <<EOF
$(url_encode_many "${host_domain}" "${host_domain}" "${ws_path}" "${name}")
EOF
      printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s#%s' \
        "$uuid" "$host" "$port" "${sni_enc}" "${host_enc}" "${ws_path_enc}" "${name_enc}"
    fi
    # 自签证书固定指纹仅在直连模式有意义：客户端直连本机、面对的就是该自签证书。
    # CDN 模式客户端面对的是前置 CDN（如 Cloudflare）边缘的公开证书，不能固定源站自签指纹，否则必然校验失败。
    if [ "$cert_mode" = "self-signed" ] && [ "${ws_mode}" != "cdn" ]; then
      # 自签证书固定指纹（新版 Xray/v2rayN 已拒绝 allowInsecure，改用 pinnedPeerCertSha256）；
      # 无证书文件（旧节点）时回退 allowInsecure=1
      fp="$(cert_fingerprint "${certificate_path}" 2>/dev/null || true)"
      if [ -n "${fp}" ]; then
        printf '&pcs=%s' "${fp}"
      else
        printf '&allowInsecure=1'
      fi
    fi
    printf '#%s' "$(url_encode "$name")"
    ;;
  anytls)
    # 批量编码 password + name（一次 jq 子进程，原逐字段 2 fork）
    { read -r password_enc; read -r name_enc; } <<EOF
$(url_encode_many "${password}" "${name}")
EOF
    tls_server="$(url_encode "${tls_server}")"
    # 自签证书：insecure=1 跳过校验；type/headerType 声明 TCP 传输，兼容主流客户端解析
    if [ "$cert_mode" = "self-signed" ]; then
      ext="insecure=1&"
    else
      ext=""
    fi
    printf 'anytls://%s@%s:%s?%ssecurity=tls&sni=%s&type=tcp&headerType=none' \
      "${password_enc}" "$host" "$port" "$ext" "$tls_server"
    printf '#%s' "${name_enc}"
    ;;
  vless-argo)
    cdn_port="${cdn_port:-443}"
    if [ -z "${endpoint_domain}" ] || [ "${endpoint_domain}" = "待分配.example.com" ]; then
      print_warn "节点 ${tag} 的 Argo 域名尚未分配（隧道可能未连上），链接暂不可用；稍后重试 sbm list。"
      return 0
    fi
    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s#%s' \
      "$uuid" "$(wrap_host "$preferred_domain")" "$cdn_port" \
      "$(url_encode "$endpoint_domain")" "$(url_encode "$endpoint_domain")" "$(url_encode "$ws_path")" "$(url_encode "$name")"
    ;;
  tuic-v5)
    tls_server="$(url_encode "${tls_server}")"
    printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&alpn=h3&sni=%s' \
      "$uuid" "$(url_encode "$password")" "$host" "$port" "$tls_server"
    if [ "$cert_mode" = "self-signed" ]; then
      printf '&allow_insecure=1'
    fi
    printf '#%s' "$(url_encode "$name")"
    ;;
  hy2)
    tls_server="$(url_encode "${tls_server}")"
    printf 'hysteria2://%s@%s:%s?sni=%s' \
      "$(url_encode "$password")" "$host" "$port" "$tls_server"
    if [ "$cert_mode" = "self-signed" ]; then
      # 自签优先固定证书指纹（新版客户端已拒绝 insecure）；无指纹再退回 insecure=1
      fp="$(cert_fingerprint "${certificate_path}" 2>/dev/null || true)"
      if [ -n "${fp}" ]; then
        printf '&pinSHA256=%s' "${fp}"
      else
        printf '&insecure=1'
      fi
    fi
    printf '#%s' "$(url_encode "$name")"
    ;;
  socks5)
    printf 'socks5://%s:%s@%s:%s#%s' \
      "$(url_encode "$username")" "$(url_encode "$password")" "$host" "$port" "$(url_encode "$name")"
    ;;
  esac
}

build_vless_argo_link() {
  build_share_link "$1"
}

