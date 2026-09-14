#!/usr/bin/env bash
set -eEuo pipefail

umask 077

REPO_OWNER="hynize"
REPO_NAME="singbox-manager"
PROJECT_VERSION="v1.5.1"
PACKAGE_NAME="singbox-manager-v1.5.1.tar.gz"
# 发布流程：scripts/build-release-bundle.sh 构建可复现 bundle，其 SHA256 与此处一致
PACKAGE_SHA256="4b3fb455a160ede0b174bfd53ff66b7901aa92344e2c7bf23ed909a98bd3b392"
PACKAGE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${PROJECT_VERSION}/${PACKAGE_NAME}"

INSTALL_BIN="/usr/local/bin/sbm"
MTP_BIN="/usr/local/bin/mtp"
LIB_DIR="/usr/local/lib/singbox-manager"
BASE_DIR="/usr/local/etc/singbox-manager"
WATCHDOG_PATH="${BASE_DIR}/watchdog.sh"
UPSTREAM_ENV="${LIB_DIR}/upstream.env"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "请使用 root 用户运行。" >&2
  exit 1
fi

download() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 10 "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    echo "需要安装 curl 或 wget。" >&2
    exit 1
  fi
}

sha256_file() {
  local target="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$target" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$target" | awk '{print $1}'
  else
    openssl dgst -sha256 "$target" | awk '{print $2}'
  fi
}

verify_bundle() {
  local bundle="$1"
  local actual
  actual="$(sha256_file "$bundle")"
  if [ "$actual" != "$PACKAGE_SHA256" ]; then
    echo "安装包校验失败。" >&2
    echo "预期值: $PACKAGE_SHA256" >&2
    echo "实际值: $actual" >&2
    exit 1
  fi
}

install_bundle() {
  local bundle="$1"
  local tmpdir root_dir

  tmpdir="$(mktemp -d)"
  tar -xzf "$bundle" -C "$tmpdir"
  root_dir="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [ -z "$root_dir" ]; then
    rm -rf "$tmpdir"
    echo "发布包结构异常：未找到根目录。" >&2
    exit 1
  fi

  # 安装前校验候选脚本语法，避免半写入造成混装
  for lib_file in "${root_dir}"/lib/*.sh; do
    if ! bash -n "${root_dir}/sb.sh" || ! bash -n "${root_dir}/mtp.sh" || ! bash -n "$lib_file" || ! bash -n "${root_dir}/scripts/watchdog.sh"; then
      rm -rf "$tmpdir"
      echo "发布包脚本语法校验失败，已取消安装。" >&2
      exit 1
    fi
  done

  install -d -m 700 "$LIB_DIR" "$BASE_DIR"
  # 先装共享库与 watchdog，最后装入口 sbm
  for lib_file in "${root_dir}"/lib/*.sh; do
    install -m 0644 "$lib_file" "${LIB_DIR}/$(basename "$lib_file")"
  done
  install -m 0644 "${root_dir}/metadata/upstream.env" "${UPSTREAM_ENV}"
  install -m 0755 "${root_dir}/scripts/watchdog.sh" "${WATCHDOG_PATH}"
  install -m 0755 "${root_dir}/sb.sh" "${INSTALL_BIN}"
  install -m 0755 "${root_dir}/mtp.sh" "${MTP_BIN}"

  chmod 0755 "${INSTALL_BIN}" "${WATCHDOG_PATH}" "${MTP_BIN}"
  chmod 0644 "${UPSTREAM_ENV}"
  for lib_file in "${LIB_DIR}"/*.sh; do
    chmod 0644 "$lib_file"
  done
  rm -rf "$tmpdir"
}

resolve_action() {
  # 显式传入动作（rep / ins）优先生效；未传参但检测到节点环境变量时，
  # 默认走非破坏性的 ins（追加），避免残留变量静默触发覆盖式重装
  local action="${1:-}"
  local var
  if [ -n "${action}" ]; then
    printf '%s' "${action}"
    return 0
  fi
  for var in vlrt wspt tupt anypt hypt socks5pt argo; do
    if [ -n "${!var:-}" ]; then
      printf 'ins'
      return 0
    fi
  done
  printf ''
}

main() {
  local bundle action mtp_install_done
  bundle="$(mktemp)"
  if ! download "${PACKAGE_URL}" "${bundle}"; then
    rm -f "${bundle}"
    echo "下载发布包失败：${PACKAGE_URL}" >&2
    exit 1
  fi
  verify_bundle "${bundle}"
  install_bundle "${bundle}"
  rm -f "${bundle}"
  echo "Singbox Manager ${PROJECT_VERSION} 安装完成：${INSTALL_BIN} / ${MTP_BIN}"

  # MTProxy 独立脚本：设了 mtpt 即调用 mtp 完成安装（与 sbm 动作完全独立）
  mtp_install_done=0
  if [ -n "${mtpt:-}" ]; then
    bash "${MTP_BIN}" || {
      echo "MTProxy 安装失败。" >&2
      exit 1
    }
    mtp_install_done=1
  fi

  action="$(resolve_action "$@")"
  if [ -n "${action}" ]; then
    exec "${INSTALL_BIN}" "${action}"
  fi
  # 既无可解析的 sbm 动作又已单独安装 mtp：直接进入 mtp 的命令入口返回（匹配页面只填 mtpt 的场景）
  if [ "${mtp_install_done}" = "1" ]; then
    exit 0
  fi
  exec "${INSTALL_BIN}"
}

main "$@"
