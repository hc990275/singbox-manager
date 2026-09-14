#!/usr/bin/env bash
set -eEuo pipefail

umask 077

read_restart_count() {
  local tag="$1"
  local file="${RUNTIME_DIR}/${tag}.restart_count"
  [ -f "${file}" ] || {
    printf '0'
    return 0
  }
  tr -dc '0-9' <"${file}" 2>/dev/null | grep -E '^[0-9]+$' || printf '0'
}

bump_restart_count() {
  local tag="$1"
  local file="${RUNTIME_DIR}/${tag}.restart_count"
  local current
  current="$(read_restart_count "$tag")"
  printf '%s' "$((current + 1))" >"${file}.tmp" && chmod 600 "${file}.tmp" && mv "${file}.tmp" "${file}"
}

reset_restart_count() {
  local tag="$1"
  rm -f "${RUNTIME_DIR}/${tag}.restart_count"
}

write_pid_file() {
  local pid_file="$1"
  local pid="$2"
  printf '%s\n' "$pid" >"$pid_file"
  chmod 600 "$pid_file"
}

read_pid_file() {
  local pid_file="$1"
  local content
  [ -f "$pid_file" ] || return 1
  content="$(tr -d ' \r\n' <"$pid_file")"
  # PID 文件只接受纯数字，拒绝负数、特殊值与被污染的内容
  [[ "${content}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${content}"
}

pid_matches_binary() {
  local pid="$1"
  local binary="$2"
  [ -n "${pid}" ] && [ -n "${binary}" ] || return 1
  local exe=""
  exe="$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)"
  [ -n "${exe}" ] || return 1
  [ "${exe}" = "${binary}" ] || [ "${exe}" = "${binary} (deleted)" ]
}

pid_matches_binary_or_alive() {
  local pid="$1"
  local binary="$2"
  [ -n "${pid}" ] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  if [ ! -d /proc ]; then
    return 0
  fi
  pid_matches_binary "${pid}" "${binary}"
}

kill_pid_file() {
  local pid_file="$1"
  local expect="${2:-}"
  local pid
  pid="$(read_pid_file "${pid_file}" 2>/dev/null || true)"
  rm -f "${pid_file}"
  [ -n "${pid}" ] || return 0

  # 提供预期二进制时先做身份校验（需 /proc，root 下可用）
  if [ -n "${expect}" ] && [ -d /proc ] && ! pid_matches_binary "${pid}" "${expect}"; then
    if kill -0 "${pid}" 2>/dev/null; then
      print_warn "PID ${pid} 已不属于 ${expect}（疑似 PID 复用），跳过终止。"
    fi
    return 0
  fi

  kill "${pid}" >/dev/null 2>&1 || return 0
  # TERM 后等待退出，最多 5 秒，仍存活则 KILL
  for _ in 1 2 3 4 5; do
    kill -0 "${pid}" 2>/dev/null || return 0
    sleep 1
  done
  kill -9 "${pid}" >/dev/null 2>&1 || true
  return 0
}

compute_go_mem_limit_mb() {
  local pct="${SBM_GOMEM_LIMIT_PCT:-45}"
  local floor_mb="${SBM_GOMEM_FLOOR_MB:-32}"
  local total_kb limit_mb v

  total_kb="$(awk '/^(MemTotal|MemTotal:)/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
  [ -n "${total_kb}" ] || total_kb=0

  local f
  for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.high; do
    [ -r "${f}" ] || continue
    v="$(tr -d ' \r\n' <"${f}" 2>/dev/null || true)"
    [ -n "${v}" ] || continue
    [ "${v}" = "max" ] && continue
    [[ "${v}" =~ ^[0-9]+$ ]] || continue
    [ "${v}" -le 0 ] && continue
    if [ "${total_kb}" -le 0 ] || [ "$((v / 1024))" -lt "${total_kb}" ]; then
      total_kb=$((v / 1024))
    fi
  done

  if [ "${total_kb}" -le 0 ]; then
    return 1
  fi

  limit_mb=$((total_kb * 1024 * pct / 100 / 1024 / 1024))
  if [ "${limit_mb}" -lt "${floor_mb}" ]; then
    limit_mb="${floor_mb}"
  fi
  printf '%s' "${limit_mb}"
}

go_mem_limit_value() {
  local mb
  mb="$(compute_go_mem_limit_mb 2>/dev/null || true)"
  [ -n "${mb}" ] || return 0
  printf '%sMiB' "${mb}"
}


systemd_available() {
  command_exists systemctl && [ -d /run/systemd/system ]
}

openrc_available() {
  command_exists rc-service && [ -x /sbin/openrc-run ]
}

systemd_timer_active() {
  local line
  line="$(systemctl list-timers --all --no-legend "${WATCHDOG_TIMER_NAME}" 2>/dev/null | head -n 1 || true)"
  [ -n "${line}" ] || return 1
  [[ "${line}" == n/a* ]] && return 1
  return 0
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

# C1：开机首检 90s→30s（端口探活并行后单轮足够快，提前拉起可缩短故障窗口）
[Timer]
OnBootSec=30
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
  if systemd_available; then
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
      printf '运行中'
    else
      printf '已停止'
    fi
    return 0
  fi

  if openrc_available; then
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
  if systemd_available; then
    systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
  elif openrc_available; then
    rc-service "${SERVICE_NAME}" stop >/dev/null 2>&1 || true
    kill_pid_file "${PID_FILE}" "${SINGBOX_BIN}"
  else
    kill_pid_file "${PID_FILE}" "${SINGBOX_BIN}"
  fi
}

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
  [ -x "${SINGBOX_BIN}" ] || fatal "尚未安装 sing-box。"
  rotate_log_file "${BASE_DIR}/logs/sing-box.log" || true
  "${SINGBOX_BIN}" check -c "${CONFIG_FILE}" >/dev/null
  warn_if_bindv6only

  local mem_limit
  mem_limit="$(go_mem_limit_value)"

  if systemd_available; then
    systemctl daemon-reload
    systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || systemctl start "${SERVICE_NAME}" >/dev/null 2>&1
    systemctl enable --now "${WATCHDOG_TIMER_NAME}" >/dev/null 2>&1 || true
  elif openrc_available; then
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

ensure_singbox_ready() {
  init_storage
  if [ ! -x "${SINGBOX_BIN}" ]; then
    print_info "检测到 sing-box 尚未安装，开始自动安装。"
    install_core
  fi
}

