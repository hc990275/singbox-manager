#!/usr/bin/env bash
set -eEuo pipefail

umask 077

# 本文件由 sb.sh 模块拆分生成：函数自原 sb.sh 原样迁出（见各自函数上方注释）。
# 依赖 lib/common.sh 提供的基础函数与全局变量，须在 common.sh 之后被 source。
detect_systemd() {
  has_systemd=false
  has_openrc=false

  if command_exists systemctl && [ -d /run/systemd/system ]; then
    has_systemd=true
  elif command_exists rc-service && [ -x /sbin/openrc-run ]; then
    has_openrc=true
  fi
}

# 守护 timer 是否真正处于"等待下一次触发"的调度态。
# 不能用 `systemctl is-active` 判定 timer：timer 单元只要被 load 就显示 active，
# 无法区分"已 enable 且等待"与"已 disable/无法触发"。改为查 list-timers 的
# NEXT 列：非 n/a（已有下一次触发计划）才算生效。
systemd_timer_active() {
  local line
  line="$(systemctl list-timers --all --no-legend "${WATCHDOG_TIMER_NAME}" 2>/dev/null | head -n 1 || true)"
  [ -n "${line}" ] || return 1
  [[ "${line}" == n/a* ]] && return 1
  return 0
}

detect_arch() {
  case "$(uname -m)" in
  x86_64 | amd64) printf 'amd64' ;;
  aarch64 | arm64) printf 'arm64' ;;
  armv7l | armv7) printf 'armv7' ;;
  armv6l | armv6) printf 'armv6' ;;
  *) return 1 ;;
  esac
}

pkg_install() {
  if command_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "$@"
  elif command_exists dnf; then
    dnf install -y "$@"
  elif command_exists yum; then
    yum install -y "$@"
  elif command_exists apk; then
    apk add --no-cache "$@"
  elif command_exists pacman; then
    pacman -Sy --noconfirm "$@"
  elif command_exists zypper; then
    zypper --non-interactive install "$@"
  else
    fatal "暂不支持当前包管理器，请手动安装以下依赖：$*"
  fi
}

required_commands() {
  printf '%s\n' curl tar jq openssl awk sed grep find head mktemp install nohup tr hostname kill rm mv chmod cat cp
  if [ "${has_systemd}" = true ]; then
    printf '%s\n' systemctl
  elif [ "${has_openrc}" = true ]; then
    printf '%s\n' rc-service rc-update
  fi
}

deps_present() {
  local cmd
  while IFS= read -r cmd; do
    command_exists "${cmd}" || return 1
  done < <(required_commands)
  command_exists ss || command_exists netstat || return 1
  return 0
}

ensure_dependencies() {
  # 依赖齐全时跳过包管理器（避免每次菜单操作都全量刷新软件源索引）
  if ! deps_present; then
    local packages=()
    if command_exists apt-get; then
      packages=(ca-certificates curl tar jq openssl procps iproute2 util-linux findutils grep sed gawk coreutils)
    elif command_exists dnf || command_exists yum; then
      packages=(ca-certificates curl tar jq openssl procps-ng iproute util-linux findutils grep sed gawk coreutils)
    elif command_exists apk; then
      packages=(ca-certificates curl tar jq openssl procps iproute2 util-linux findutils grep sed gawk coreutils gcompat)
    elif command_exists pacman; then
      packages=(ca-certificates curl tar jq openssl procps-ng iproute2 util-linux findutils grep sed gawk coreutils)
    elif command_exists zypper; then
      packages=(ca-certificates curl tar jq openssl procps iproute2 util-linux findutils grep sed gawk coreutils)
    fi

    pkg_install "${packages[@]}"
  fi
  verify_runtime_prereqs
}

verify_runtime_prereqs() {
  local missing=() cmd
  while IFS= read -r cmd; do
    command_exists "${cmd}" || missing+=("${cmd}")
  done < <(required_commands)

  if ! command_exists ss && ! command_exists netstat; then
    missing+=("ss/netstat")
  fi

  if [ "${#missing[@]}" -gt 0 ]; then
    fatal "缺少必要命令：${missing[*]}"
  fi
}

ensure_binary_runs() {
  local binary="$1"
  local label="$2"
  shift 2

  if "$binary" "$@" >/dev/null 2>&1; then
    return 0
  fi

  if command_exists apk; then
    print_info "检测到 Alpine，正在安装 gcompat 兼容层"
    apk add --no-cache gcompat >/dev/null 2>&1
  fi

  "$binary" "$@" >/dev/null 2>&1 || fatal "${label} 已安装，但当前系统无法运行。"
}

sync_project_assets_from_source() {
  if [ -z "${SOURCE_ROOT}" ]; then
    return 0
  fi

  init_storage
  install -d -m 700 "${LIB_DIR}" "${BASE_DIR}"
  install -m 0755 "${SOURCE_ROOT}/sb.sh" "${INSTALL_BIN}"
  install -m 0644 "${SOURCE_ROOT}/lib/common.sh" "${LIB_DIR}/common.sh"
  for sbm_module in ui core nodes menu; do
    install -m 0644 "${SOURCE_ROOT}/lib/${sbm_module}.sh" "${LIB_DIR}/${sbm_module}.sh"
  done
  install -m 0644 "${SOURCE_ROOT}/metadata/upstream.env" "${UPSTREAM_ENV}"
  install -m 0755 "${SOURCE_ROOT}/scripts/watchdog.sh" "${WATCHDOG_TARGET}"
  sanitize_permissions
}

install_release_bundle() {
  local tag="$1"
  local bundle_url checksums_url bundle_name tmpdir bundle_file checksums_file expected root_dir

  tmpdir="$(mktemp -d)"
  bundle_name="singbox-manager-${tag}.tar.gz"
  bundle_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${tag}/${bundle_name}"
  checksums_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${tag}/checksums.txt"
  bundle_file="${tmpdir}/${bundle_name}"
  checksums_file="${tmpdir}/checksums.txt"

  download_file "${checksums_url}" "${checksums_file}" || {
    rm -rf "${tmpdir}"
    fatal "下载 checksums.txt 失败。"
  }
  download_file "${bundle_url}" "${bundle_file}" || {
    rm -rf "${tmpdir}"
    fatal "下载 ${bundle_name} 失败。"
  }

  # 兼容 GNU sha256sum 二进制模式输出（文件名带 * 前缀）与 CRLF
  expected="$(awk -v file="${bundle_name}" '{ sub(/\r$/, "", $2); sub(/^\*/, "", $2); if ($2 == file) print $1 }' "${checksums_file}")"
  [ -n "${expected}" ] || fatal "未找到 ${bundle_name} 的校验值。"
  verify_sha256 "${bundle_file}" "${expected}"

  tar -xzf "${bundle_file}" -C "${tmpdir}"
  root_dir="$(find "${tmpdir}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [ -n "${root_dir}" ] || {
    rm -rf "${tmpdir}"
    fatal "发布包结构异常：未找到根目录。"
  }

  # 安装前先校验候选脚本，避免中断/半写入造成新旧版本混装
  if ! bash -n "${root_dir}/sb.sh" || ! bash -n "${root_dir}/lib/common.sh" || ! bash -n "${root_dir}/scripts/watchdog.sh"; then
    rm -rf "${tmpdir}"
    fatal "发布包脚本语法校验失败，已取消安装（原文件未改动）。"
  fi

  install -d -m 700 "${LIB_DIR}" "${BASE_DIR}"
  # 先装共享库与 watchdog，最后装入口 sbm，保证入口加载到配套实现
  install -m 0644 "${root_dir}/lib/common.sh" "${LIB_DIR}/common.sh"
  for sbm_module in ui core nodes menu; do
    if ! bash -n "${root_dir}/lib/${sbm_module}.sh"; then
      rm -rf "${tmpdir}"
      fatal "发布包脚本语法校验失败，已取消安装（原文件未改动）。"
    fi
    install -m 0644 "${root_dir}/lib/${sbm_module}.sh" "${LIB_DIR}/${sbm_module}.sh"
  done
  install -m 0644 "${root_dir}/metadata/upstream.env" "${UPSTREAM_ENV}"
  install -m 0755 "${root_dir}/scripts/watchdog.sh" "${WATCHDOG_TARGET}"
  install -m 0755 "${root_dir}/sb.sh" "${INSTALL_BIN}"
  sanitize_permissions
  rm -rf "${tmpdir}"
}

install_singbox_core() {
  local arch asset tmpdir archive binary expected
  local -a urls
  arch="$(detect_arch)" || fatal "暂不支持当前 CPU 架构：$(uname -m)"
  asset="${SINGBOX_ASSET[$arch]:-}"
  expected="${SINGBOX_SHA256[$arch]:-}"
  [ -n "${asset}" ] || fatal "未配置 ${arch} 对应的 sing-box 安装包。"
  [ -n "${expected}" ] || fatal "未配置 ${arch} 对应的 sing-box 校验值。"

  # 官方源优先，官方源不可达时回退本仓库镜像（SHA256 校验不因换源放松）
  local -a urls=()
  urls+=("https://github.com/SagerNet/sing-box/releases/download/${SINGBOX_VERSION}/${asset}")
  [ -n "${SINGBOX_MIRROR_BASE:-}" ] && urls+=("${SINGBOX_MIRROR_BASE}/${asset}")

  tmpdir="$(mktemp -d)"
  archive="${tmpdir}/${asset}"
  print_info "正在安装 sing-box ${SINGBOX_VERSION} (${arch})"
  if ! download_file_multi "${archive}" "${urls[@]}"; then
    rm -rf "${tmpdir}"
    fatal "下载 sing-box 失败（已尝试 ${#urls[@]} 个源）。"
  fi
  verify_sha256 "${archive}" "${expected}"
  tar -xzf "${archive}" -C "${tmpdir}"
  binary="$(find "${tmpdir}" -type f -name sing-box | head -n 1)"
  [ -n "${binary}" ] || fatal "安装包中未找到 sing-box 可执行文件。"
  install -m 0755 "${binary}" "${SINGBOX_BIN}"
  ensure_binary_runs "${SINGBOX_BIN}" "sing-box" version
  rm -rf "${tmpdir}"
  print_ok "sing-box 已安装到 ${SINGBOX_BIN}"
}

install_cloudflared_bin() {
  local arch asset tmpfile expected version
  local verify_mode
  arch="$(detect_arch)" || fatal "暂不支持当前 CPU 架构：$(uname -m)"
  asset="${CLOUDFLARED_ASSET[$arch]:-}"
  [ -n "${asset}" ] || fatal "未配置 ${arch} 对应的 cloudflared 安装包。"

  # 校验模式：sha256=官方 digest 完整校验；runtime=digest 不可得时降级为
  # "来源仍为官方 Release + 下载后实测版本一致 + 可执行校验"；固定版本表始终完整校验
  #
  # 供应链安全（对齐 sing-box 的强校验模型）：除非用户显式开启 runtime 校验
  # 降级（CLOUDFLARED_ALLOW_RUNTIME_VERIFY=1），否则在拿不到可信 digest 时
  # **fail-closed 拒绝安装**——运行时可执行 + 自报版本一致不能证明二进制内容
  # 来自 Cloudflare/官方源（镜像源被污染时仍可通过）。
  verify_mode="sha256"
  version="${CLOUDFLARED_VERSION:-}"
  expected="${CLOUDFLARED_SHA256[$arch]:-}"
  if [ "${CLOUDFLARED_LATEST:-false}" = "true" ]; then
    # 第一层：GitHub API（版本+digest）
    if version="$(cloudflared_latest_version)" && expected="$(cloudflared_latest_digest "${asset}")"; then
      print_info "cloudflared 官方最新版本：${version}"
    else
      # 第二层：版本经 jsdelivr/固定表确定。默认 fail-closed：
      # 仅当解析出的版本恰好等于固定回退版本（可完整 SHA256 校验）时才继续。
      expected=""
      if [ -z "${version}" ]; then
        version="${CLOUDFLARED_FALLBACK_VERSION:-}"
      fi
      [ -n "${version}" ] || fatal "无法获取 cloudflared 最新版本，且未配置回退版本，拒绝继续安装。"
      if [ -n "${CLOUDFLARED_SHA256[$arch]:-}" ] && [ "${version}" = "${CLOUDFLARED_FALLBACK_VERSION:-}" ]; then
        # 版本与固定回退版本一致时仍可用固定 digest 完整校验
        expected="${CLOUDFLARED_SHA256[$arch]}"
        verify_mode="sha256"
        print_warn "GitHub API 不可用，回退固定版本 cloudflared ${version}（完整 SHA256 校验）。"
      elif [ "${CLOUDFLARED_ALLOW_RUNTIME_VERIFY:-0}" = "1" ]; then
        # 显式允许 runtime 降级（默认关闭）：仍需保证固定表有该版本 digest 才可完整校验
        if [ -n "${CLOUDFLARED_SHA256[$arch]:-}" ]; then
          expected="${CLOUDFLARED_SHA256[$arch]}"
          verify_mode="sha256"
          print_warn "GitHub API 不可用，已用固定版本表 digest 完整校验 cloudflared ${version}。"
        else
          verify_mode="runtime"
          print_warn "无法获取 cloudflared ${version} 的官方 digest，已按显式配置降级为运行时版本校验（来源仍为官方 Release）。"
        fi
      else
        rm -f "${tmpfile:-}"
        fatal "无法获取 cloudflared ${version} 的可信 SHA256 digest，拒绝安装未校验的二进制。可设置 CLOUDFLARED_ALLOW_RUNTIME_VERIFY=1 显式接受更低校验强度。"
      fi
    fi
  else
    [ -n "${version}" ] || fatal "未配置 cloudflared 版本。"
    [ -n "${expected}" ] || fatal "未配置 ${arch} 对应的 cloudflared 校验值，拒绝安装未校验的二进制。"
  fi

  # 官方源优先，官方源不可达时回退本仓库镜像
  local -a urls=()
  urls+=("https://github.com/cloudflare/cloudflared/releases/download/${version}/${asset}")
  [ -n "${CLOUDFLARED_MIRROR_BASE:-}" ] && urls+=("${CLOUDFLARED_MIRROR_BASE}/${asset}")

  tmpfile="$(mktemp)"
  print_info "正在安装 cloudflared ${version} (${arch})"
  if ! download_file_multi "${tmpfile}" "${urls[@]}"; then
    rm -f "${tmpfile}"
    fatal "下载 cloudflared 失败（已尝试 ${#urls[@]} 个源）。"
  fi

  if [ "${verify_mode}" = "sha256" ]; then
    verify_sha256 "${tmpfile}" "${expected}"
  else
    # 运行时校验：二进制可执行且自报版本与期望一致，防损坏/HTML 错误页/错版本
    chmod 0755 "${tmpfile}"
    local actual_version
    actual_version="$("${tmpfile}" version 2>/dev/null | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' | head -n 1 || true)"
    [ "${actual_version}" = "${version}" ] || {
      rm -f "${tmpfile}"
      fatal "cloudflared 运行时校验失败：期望 ${version}，实际 ${actual_version:-无法运行}。"
    }
  fi
  install -m 0755 "${tmpfile}" "${CLOUDFLARED_BIN}"
  ensure_binary_runs "${CLOUDFLARED_BIN}" "cloudflared" version
  rm -f "${tmpfile}"
  print_ok "cloudflared 已安装到 ${CLOUDFLARED_BIN}（${version}，校验：${verify_mode}）"
}

create_systemd_units() {
  local mem_line=""
  local mem_limit gogc_line memory_high_line memory_max_line nofile_line
  local mem_high mem_max
  mem_limit="$(go_mem_limit_value)"
  if [ -n "${mem_limit}" ]; then
    mem_line="Environment=GOMEMLIMIT=${mem_limit}"
  fi
  # P5：GOGC=off 彻底关闭逃逸堆目标（可选）；MemoryHigh/MemoryMax 软硬内存上限（可选）
  gogc_line=""
  if go_gc_requested; then
    gogc_line="Environment=GOGC=off"
  fi
  mem_high="$(manager_env_or_setting "mem_high_mb")"
  mem_max="$(manager_env_or_setting "mem_max_mb")"
  memory_high_line=""
  memory_max_line=""
  if [ -n "${mem_high}" ] && [[ "${mem_high}" =~ ^[0-9]+$ ]] && [ "${mem_high}" -gt 0 ]; then
    memory_high_line="MemoryHigh=${mem_high}M"
  fi
  if [ -n "${mem_max}" ] && [[ "${mem_max}" =~ ^[0-9]+$ ]] && [ "${mem_max}" -gt 0 ]; then
    memory_max_line="MemoryMax=${mem_max}M"
  fi
  # P2：放宽文件描述符上限，适配高连接数
  nofile_line="LimitNOFILE=1048576"

  cat >"${SYSTEMD_SERVICE_FILE}" <<EOF
[Unit]
Description=Singbox Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${BASE_DIR}
ExecStartPre=/bin/mkdir -p ${BASE_DIR}/logs ${RUNTIME_DIR}
ExecStartPre=${SINGBOX_BIN} check -c ${CONFIG_FILE}
${mem_line}
${gogc_line}
${memory_high_line}
${memory_max_line}
${nofile_line}
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectProc=invisible
ProcSubset=pid
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
ReadWritePaths=${BASE_DIR}

[Install]
WantedBy=multi-user.target
EOF

  cat >"${SYSTEMD_WATCHDOG_SERVICE_FILE}" <<EOF
[Unit]
Description=Singbox Manager Watchdog
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${WATCHDOG_TARGET}
KillMode=process
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectProc=invisible
ProcSubset=pid
ReadWritePaths=${BASE_DIR}
EOF

  cat >"${SYSTEMD_WATCHDOG_TIMER_FILE}" <<EOF
[Unit]
Description=Run Singbox Manager Watchdog Every Minute

[Timer]
OnBootSec=90
OnUnitActiveSec=60
Unit=${WATCHDOG_SERVICE_NAME}.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl enable --now "${WATCHDOG_TIMER_NAME}" >/dev/null 2>&1 || true
}

create_openrc_units() {
  local mem_line gogc_line
  local mem_limit
  mem_line=""
  gogc_line=""
  mem_limit="$(go_mem_limit_value)"
  if [ -n "${mem_limit}" ]; then
    mem_line="export GOMEMLIMIT=${mem_limit}"
  fi
  if go_gc_requested; then
    gogc_line="export GOGC=off"
  fi

  cat >"${OPENRC_SERVICE_FILE}" <<EOF
#!/sbin/openrc-run

name="${SERVICE_NAME}"
description="Singbox Manager"
command="${SINGBOX_BIN}"
command_args="run -c ${CONFIG_FILE}"
command_background=true
pidfile="${PID_FILE}"

depend() {
  need net
}

start_pre() {
  mkdir -p ${BASE_DIR}/logs ${RUNTIME_DIR}
  ${SINGBOX_BIN} check -c ${CONFIG_FILE} >/dev/null
  ${mem_line}
  ${gogc_line}
}
EOF

  chmod 0755 "${OPENRC_SERVICE_FILE}"
  rc-update add "${SERVICE_NAME}" default >/dev/null 2>&1 || true

  if command_exists rc-service && [ -x /etc/init.d/crond ]; then
    rc-update add crond default >/dev/null 2>&1 || true
    rc-service crond start >/dev/null 2>&1 || true
  fi
}

create_cron_watchdog() {
  if ! command_exists crontab; then
    print_warn "未找到 crontab，已跳过 watchdog 的 cron 创建。"
    return 0
  fi

  (
    crontab -l 2>/dev/null | grep -Fv "${WATCHDOG_TARGET}" | grep -Fv "no crontab for" || true
    echo "* * * * * ${WATCHDOG_TARGET} >/dev/null 2>&1"
  ) | crontab -
}

service_state() {
  detect_systemd
  if [ "${has_systemd}" = true ]; then
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
      printf '运行中'
    else
      printf '已停止'
    fi
    return 0
  fi

  if [ "${has_openrc}" = true ]; then
    if rc-service "${SERVICE_NAME}" status >/dev/null 2>&1; then
      printf '运行中'
    else
      printf '已停止'
    fi
    return 0
  fi

  local pid
  pid="$(read_pid_file "${PID_FILE}" 2>/dev/null || true)"
  # 存活且确为 sing-box 实例才显示运行中，防止 PID 复用导致误报
  if [ -n "${pid}" ] && pid_matches_binary_or_alive "${pid}" "${SINGBOX_BIN}"; then
    printf '运行中'
  else
    printf '已停止'
  fi
}

stop_service() {
  detect_systemd
  if [ "${has_systemd}" = true ]; then
    systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
  elif [ "${has_openrc}" = true ]; then
    rc-service "${SERVICE_NAME}" stop >/dev/null 2>&1 || true
    kill_pid_file "${PID_FILE}" "${SINGBOX_BIN}"
  else
    kill_pid_file "${PID_FILE}" "${SINGBOX_BIN}"
  fi
}

# 低内存守卫：小内存机（默认 <200MB）提示资源约束；watchdog/cloudflared 侧已自动收紧
ensure_low_memory_guard() {
  local total_kb avail_mb low_mb
  low_mb="${SBM_LOW_MEM_MB:-200}"
  total_kb="$(awk '/^(MemTotal|MemTotal:)/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
  [ -n "${total_kb}" ] || return 0
  avail_mb=$((total_kb / 1024))
  if [ "${avail_mb}" -lt "${low_mb}" ]; then
    print_warn "检测到低内存环境（约 ${avail_mb}MB < ${low_mb}MB）：已为 sing-box/cloudflared 设置 GOMEMLIMIT 软上限并强制 cloudflared http2 模式。"
    print_warn "建议少开协议节点、避免同时开启多个 Argo 节点；隧道进程内存尖峰靠 Go 软上限抑制。"
  fi
}

start_service() {
  detect_systemd
  [ -x "${SINGBOX_BIN}" ] || fatal "尚未安装 sing-box。"
  rotate_log_file "${BASE_DIR}/logs/sing-box.log" || true
  "${SINGBOX_BIN}" check -c "${CONFIG_FILE}" >/dev/null
  warn_if_bindv6only

  local mem_limit
  mem_limit="$(go_mem_limit_value)"

  if [ "${has_systemd}" = true ]; then
    systemctl daemon-reload
    systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || systemctl start "${SERVICE_NAME}" >/dev/null 2>&1
    systemctl enable --now "${WATCHDOG_TIMER_NAME}" >/dev/null 2>&1 || true
  elif [ "${has_openrc}" = true ]; then
    stop_service
    rc-service "${SERVICE_NAME}" restart >/dev/null 2>&1 || rc-service "${SERVICE_NAME}" start >/dev/null 2>&1
  else
    stop_service
    local env_prefix=()
    if [ -n "${mem_limit}" ]; then
      env_prefix+=(GOMEMLIMIT="${mem_limit}")
    fi
    # P5：可选 GOGC=off（彻底关闭逃逸堆目标，适合希望避免频繁 GC 的场景）
    if go_gc_requested; then
      env_prefix+=(GOGC="off")
    fi
    if [ "${#env_prefix[@]}" -gt 0 ]; then
      nohup env "${env_prefix[@]}" "${SINGBOX_BIN}" run -c "${CONFIG_FILE}" >>"${BASE_DIR}/logs/sing-box.log" 2>&1 &
    else
      nohup "${SINGBOX_BIN}" run -c "${CONFIG_FILE}" >>"${BASE_DIR}/logs/sing-box.log" 2>&1 &
    fi
    write_pid_file "${PID_FILE}" "$!"
  fi

  print_ok "服务状态：$(service_state)"
}

install_core() {
  detect_systemd
  acquire_lock
  ensure_dependencies
  init_storage
  sync_project_assets_from_source
  install_singbox_core
  install_cloudflared_bin
  ensure_low_memory_guard
  render_config
  apply_network_tune
  if [ "${has_systemd}" = true ]; then
    create_systemd_units
  elif [ "${has_openrc}" = true ]; then
    create_openrc_units
    create_cron_watchdog
  else
    create_cron_watchdog
  fi
  start_service
  restart_all_argo_nodes
  sanitize_permissions
  release_lock
}

ensure_singbox_ready() {
  init_storage
  if [ ! -x "${SINGBOX_BIN}" ]; then
    print_info "检测到 sing-box 尚未安装，开始自动安装。"
    install_core
  fi
}

update_script() {
  local latest_tag
  # 首选 GitHub API；不可用时回退 jsdelivr 镜像索引（只接受 v0.0.0 语义化 tag，
  # 防止二进制镜像等特殊 tag 混入）
  latest_tag="$(curl -fsSL --retry 3 --retry-delay 2 -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)"
  if [ -z "${latest_tag}" ]; then
    latest_tag="$(curl -fsSL --retry 2 --max-time 20 "https://data.jsdelivr.com/v1/package/gh/${REPO_OWNER}/${REPO_NAME}" 2>/dev/null | jq -r '.versions[]? | select(type == "string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))' 2>/dev/null | head -n 1 || true)"
    [ -n "${latest_tag}" ] && print_info "GitHub API 不可用，已经 jsdelivr 获取最新版本：${latest_tag}"
  fi
  [ -n "${latest_tag}" ] || fatal "无法获取最新发布版本。"
  acquire_lock
  install_release_bundle "${latest_tag}"
  sanitize_permissions
  # 让运行中的服务与新版本文件保持一致（配置未变时仅为快速重启）
  if [ -x "${SINGBOX_BIN}" ] && [ -f "${CONFIG_FILE}" ]; then
    print_info "重启服务以应用新版本..."
    start_service || true
    restart_all_argo_nodes || true
  fi
  release_lock
  print_ok "项目文件已更新到 ${latest_tag}"
}

uninstall_project() {
  local tag
  if ! confirm_yes "这将卸载 ${PROJECT_NAME}，是否继续？"; then
    print_info "已取消卸载。"
    return 1
  fi

  detect_systemd
  acquire_lock
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    stop_argo_node "${tag}"
  done < <(iter_node_tags)

  stop_service || true

  if [ "${has_systemd}" = true ]; then
    systemctl disable --now "${WATCHDOG_TIMER_NAME}" >/dev/null 2>&1 || true
    systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
    rm -f "${SYSTEMD_SERVICE_FILE}" "${SYSTEMD_WATCHDOG_SERVICE_FILE}" "${SYSTEMD_WATCHDOG_TIMER_FILE}"
    systemctl daemon-reload || true
  elif [ "${has_openrc}" = true ]; then
    rc-update del "${SERVICE_NAME}" default >/dev/null 2>&1 || true
    rm -f "${OPENRC_SERVICE_FILE}"
  fi

  if command_exists crontab; then
    (crontab -l 2>/dev/null | grep -Fv "${WATCHDOG_TARGET}" | grep -Fv "no crontab for" || true) | crontab -
  fi

  rm -rf "${BASE_DIR}" "${LIB_DIR}" "${INSTALL_BIN}" "${SINGBOX_BIN}" "${CLOUDFLARED_BIN}"
  release_lock
  print_ok "项目已卸载。"
  return 0
}
