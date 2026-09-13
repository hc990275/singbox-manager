#!/usr/bin/env bash
set -eEuo pipefail

umask 077

# 本文件由 sb.sh 模块拆分生成：函数自原 sb.sh 原样迁出（见各自函数上方注释）。
# 依赖 lib/common.sh 提供的基础函数与全局变量，须在 common.sh 之后被 source。

normalize_input() {
  local value="$1"
  printf '%s' "$value" |
    tr -d '\000-\037\177' |
    sed -e 's/\r//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

prompt_with_default() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "${prompt} [${default}]: " value
  value="$(normalize_input "${value:-$default}")"
  printf '%s' "${value:-$default}"
}

prompt_nonempty() {
  local prompt="$1"
  local value=""
  while [ -z "$value" ]; do
    read -r -p "${prompt}: " value
    value="$(normalize_input "$value")"
  done
  printf '%s' "$value"
}

prompt_optional_value() {
  local prompt="$1"
  local value
  read -r -p "${prompt}: " value
  normalize_input "$value"
}

confirm_yes() {
  local prompt="$1"
  local answer
  read -r -p "${prompt} [y/N]: " answer
  answer="$(normalize_input "$answer")"
  [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss]|是)$ ]]
}

prompt_choice() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "${prompt} [${default}]: " value
  value="$(normalize_input "${value:-$default}")"
  printf '%s' "${value,,}"
}

prompt_positive_integer() {
  local prompt="$1"
  local default="$2"
  local value
  while true; do
    value="$(prompt_with_default "${prompt}" "${default}")"
    if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ]; then
      printf '%s' "$value"
      return 0
    fi
    print_warn "${prompt} 必须是大于 0 的整数。"
  done
}

# 域名/SNI 交互输入：循环直至通过白名单校验
prompt_safe_domain() {
  local prompt="$1"
  local default="$2"
  local value
  while true; do
    value="$(prompt_with_default "${prompt}" "${default}")"
    if is_safe_domain "${value}"; then
      printf '%s' "${value}"
      return 0
    fi
    print_warn "域名格式无效：${value}（仅允许字母数字与 . _ : -）"
  done
}

# WS 类节点连接地址确认：默认优选域名仅在前置 CDN 已接入本机时可用，
# 用户无意识回车会拿到"死节点"，故采用默认值前必须显式确认
prompt_cdn_domain() {
  local value
  while true; do
    value="$(prompt_safe_domain "连接地址（优选 IP/域名）" "${DEFAULT_CDN_DOMAIN}")"
    if [ "${value}" != "${DEFAULT_CDN_DOMAIN}" ]; then
      printf '%s' "${value}"
      return 0
    fi
    print_warn "内置优选域名 ${DEFAULT_CDN_DOMAIN} 仅在该域名已接入本机前置 CDN 时可用；没有自备域名请填优选 IP 或你自己的域名。"
    if confirm_yes "确认仍使用 ${DEFAULT_CDN_DOMAIN}？"; then
      printf '%s' "${value}"
      return 0
    fi
  done
}

prompt_port() {
  local default="$1"
  local port
  while true; do
    port="$(prompt_with_default "端口" "$default")"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
      print_warn "端口无效：${port}"
      continue
    fi
    if ! port_available "$port"; then
      print_warn "端口 ${port} 已被占用。"
      continue
    fi
    printf '%s' "$port"
    return 0
  done
}
