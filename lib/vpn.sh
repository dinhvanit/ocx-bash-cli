#!/usr/bin/env bash
# ocx — VPN profile discovery, health checks, backends, and commands.

# ---------------------------------------------------------------------------
# Region helpers
# ---------------------------------------------------------------------------
normalize_region() {
  local r
  r="$(lower "${1:-}")"
  r="${r#vpn_}"; r="${r#vpn-}"; r="${r#vpngate_}"; r="${r#vpngate-}"
  case "$r" in
    vn|vietnam|viet-nam|viet) printf 'vn' ;;
    jp|japan|nippon)         printf 'jp' ;;
    us|usa|america|united-state|united_state|united-states|united_states) printf 'us' ;;
    sg|singapore)            printf 'sg' ;;
    kr|korea|south-korea|south_korea) printf 'kr' ;;
    tw|taiwan)               printf 'tw' ;;
    hk|hongkong|hong-kong)   printf 'hk' ;;
    th|thailand)             printf 'th' ;;
    my|malaysia)             printf 'my' ;;
    id|indonesia)            printf 'id' ;;
    ph|philippines)          printf 'ph' ;;
    gb|uk|united-kingdom|united_kingdom|britain|wales) printf 'gb' ;;
    de|germany)              printf 'de' ;;
    fr|france)               printf 'fr' ;;
    nl|netherlands)          printf 'nl' ;;
    ca|canada)               printf 'ca' ;;
    au|australia)            printf 'au' ;;
    in|india)                printf 'in' ;;
    ru|russia|russian-federation|russian_federation) printf 'ru' ;;
    ae|uae|united-arab-emirates|united_arab_emirates) printf 'ae' ;;
    vpngate|vpngate-public|public|public-vpn|opengw) printf 'misc' ;;
    *)                       printf '%s' "${r:-misc}" ;;
  esac
}

region_from_filename() {
  local base="$1" first
  base="$(lower "$base")"
  first="${base%%[-_.]*}"
  if [[ "$first" =~ ^[a-z]{2,3}$ ]]; then
    normalize_region "$first"
  else
    printf 'misc'
  fi
}

region_from_path() {
  local file="$1" dir rel first line
  dir="$(dirname "$file")"
  if [[ "$dir" == "$OCX_VPN_DIR" || "$dir" == "$OCX_WG_DIR" ]]; then
    region_from_filename "$(basename "$file")"
    return
  fi
  rel=""
  if [[ "$dir" == "$OCX_VPN_DIR"/* ]]; then rel="${dir#"$OCX_VPN_DIR"/}"; fi
  if [[ "$dir" == "$OCX_WG_DIR"/* ]]; then rel="${dir#"$OCX_WG_DIR"/}"; fi
  if [[ -n "$rel" ]]; then
    first="${rel%%/*}"
    normalize_region "$first"
    return
  fi
  # Optional explicit comment: # ocx-region: jp
  line=$(grep -m1 -E '^[[:space:]]*#[[:space:]]*ocx-region[[:space:]]*:' "$file" 2>/dev/null || true)
  if [[ -n "$line" ]]; then
    normalize_region "${line#*:}"
    return
  fi
  region_from_filename "$(basename "$file")"
}

# ---------------------------------------------------------------------------
# Profile discovery. Output lines:
#   backend<TAB>name<TAB>absolute-path<TAB>region
# name is the relative path without the final extension. This allows both
# vn/vn-01 and a flat vn-01 file.
# ---------------------------------------------------------------------------
discover_profiles() {
  local backend dir root file rel name region
  while IFS=$'\t' read -r backend dir; do
    root="$dir"
    while IFS= read -r -d '' file; do
      rel="${file#"$root"/}"
      name="${rel%.*}"
      region="$(region_from_path "$file")"
      printf '%s\t%s\t%s\t%s\n' "$backend" "$name" "$file" "$region"
    done < <(find "$root" -type f -name "$([[ "$backend" == openvpn ]] && printf '*.ovpn' || printf '*.conf')" -print0 2>/dev/null)
  done < <(printf 'openvpn\t%s\nwireguard\t%s\n' "$OCX_VPN_DIR" "$OCX_WG_DIR")
}

list_profiles() {
  local region="${1:-}" backend="${2:-}"
  discover_profiles | while IFS=$'\t' read -r b n p r; do
    [[ -n "$backend" && "$b" != "$backend" ]] && continue
    [[ -n "$region" && "$r" != "$region" ]] && continue
    printf '%s\t%s\t%s\t%s\n' "$b" "$n" "$p" "$r"
  done | sort -t $'\t' -k4,4 -k2,2
}

profile_names() {
  list_profiles "${1:-}" "${2:-}" | cut -f2
}

# Resolve user input to one profile line. Accepts:
#   exact name, basename, suffix (jp/jp-01), unique basename.
profile_resolve() {
  local query="${1:-}" entries matches count line
  [[ -n "$query" ]] || return 1

  # Cho phép chọn theo số thứ tự trong `ocx vpn list`.
  if [[ "$query" =~ ^[0-9]+$ ]] && (( query > 0 )); then
    line="$(list_profiles | sed -n "${query}p")"
    if [[ -n "$line" ]]; then printf '%s\n' "$line"; return 0; fi
    printf 'ocx: không có profile số %s. Xem: ocx vpn list\n' "$query" >&2
    return 1
  fi

  entries="$(discover_profiles)"

  # exact name
  matches="$(awk -F'\t' -v q="$query" '$2 == q' <<< "$entries")"
  count="$(grep -c . <<< "$matches" || true)"
  if (( count == 1 )); then printf '%s\n' "$matches"; return 0; fi
  if (( count > 1 )); then
    printf 'ocx: tên profile không duy nhất: %s\n' "$query" >&2
    printf '%s\n' "$matches" | cut -f2 | sed 's/^/  /' >&2
    return 2
  fi

  # unique basename or suffix
  matches="$(awk -F'\t' -v q="$query" '
    {
      n = $2
      base = n; sub(/^.*\//, "", base)
      if (base == q || n ~ ("/" q "$")) print
    }' <<< "$entries")"
  count="$(grep -c . <<< "$matches" || true)"
  if (( count == 1 )); then printf '%s\n' "$matches"; return 0; fi
  if (( count > 1 )); then
    printf 'ocx: có nhiều profile khớp "%s":\n' "$query" >&2
    printf '%s\n' "$matches" | cut -f2 | sed 's/^/  /' >&2
    return 2
  fi

  printf 'ocx: không tìm thấy profile "%s". Xem: ocx vpn list\n' "$query" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Public IP
# ---------------------------------------------------------------------------
fetch_ip() {
  local url ip
  for url in "${OCX_HEALTH_URLS[@]}"; do
    ip="$("$CURL_BIN" -4fsS --connect-timeout 3 --max-time 8 "$url" 2>/dev/null \
      | tr -d '[:space:]' || true)"
    if is_ipv4 "$ip"; then printf '%s' "$ip"; return 0; fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# OpenVPN
# ---------------------------------------------------------------------------
openvpn_pidfile() { printf '%s' "$OCX_OPENVPN_PID_FILE"; }
openvpn_logfile() { printf '%s/openvpn-%s.log' "$OCX_LOG_DIR" "$(safe_name "$1")"; }
openvpn_statusfile() { printf '%s/openvpn-%s.status' "$OCX_LOG_DIR" "$(safe_name "$1")"; }

openvpn_pid() {
  local pf
  pf="$(openvpn_pidfile)"
  [[ -s "$pf" ]] || return 1
  read_file_root "$pf" 2>/dev/null | tr -dc '0-9'
}

openvpn_alive() {
  local pid cmd
  pid="$(openvpn_pid 2>/dev/null || true)"
  proc_exists "$pid" || return 1
  cmd="$(proc_cmdline "$pid" 2>/dev/null || true)"
  [[ "$cmd" == *openvpn* ]] || return 1
  # Ensure this is the process started with our pidfile.
  [[ "$cmd" == *"$OCX_OPENVPN_PID_FILE"* ]] || return 1
  return 0
}

openvpn_connect() {
  local path="$1" name="$2" logfile pidfile statusfile
  require_cmd "$OPENVPN_BIN"
  prepare_sudo
  logfile="$(openvpn_logfile "$name")"
  pidfile="$(openvpn_pidfile)"
  statusfile="$(openvpn_statusfile "$name")"
  mkdir -p "$OCX_LOG_DIR"
  : > "$logfile"; chmod 600 "$logfile" 2>/dev/null || true
  : > "$pidfile"; chmod 600 "$pidfile" 2>/dev/null || true
  : > "$statusfile"; chmod 600 "$statusfile" 2>/dev/null || true

  info "khởi động OpenVPN: $name"
  if ! run_root "$OPENVPN_BIN" --config "$path" --daemon \
      --writepid "$pidfile" --log "$logfile" --status "$statusfile" 10; then
    warn "OpenVPN không khởi động được; log: $logfile"
    tail -n 30 "$logfile" 2>/dev/null >&2 || true
    return 1
  fi

  local i
  for i in {1..15}; do
    [[ -s "$pidfile" ]] && break
    sleep 1
  done
  if ! openvpn_alive; then
    warn "OpenVPN dừng ngay sau khi khởi động; log: $logfile"
    tail -n 30 "$logfile" 2>/dev/null >&2 || true
    return 1
  fi
  return 0
}

openvpn_disconnect() {
  local pid start current_start logfile
  state_load
  pid="${ACTIVE_PID:-}"
  if [[ -z "$pid" ]]; then
    pid="$(openvpn_pid 2>/dev/null || true)"
  fi
  if [[ -z "$pid" ]] || ! proc_exists "$pid"; then
    rm -f "$(openvpn_pidfile)" 2>/dev/null || true
    return 0
  fi

  local cmd
  cmd="$(proc_cmdline "$pid" 2>/dev/null || true)"
  if [[ "$cmd" != *openvpn* || "$cmd" != *"$OCX_OPENVPN_PID_FILE"* ]]; then
    warn "PID $pid không phải OpenVPN do ocx quản lý; bỏ qua"
    return 1
  fi
  if [[ -n "${ACTIVE_PATH:-}" && "$cmd" != *"$ACTIVE_PATH"* ]]; then
    warn "PID $pid không dùng profile trong state; bỏ qua"
    return 1
  fi
  if [[ -n "${ACTIVE_PID_START:-}" ]]; then
    current_start="$(proc_start_ticks "$pid" 2>/dev/null || true)"
    if [[ -n "$current_start" && "$current_start" != "$ACTIVE_PID_START" ]]; then
      warn "PID $pid đã bị tái sử dụng; không gửi tín hiệu"
      return 1
    fi
  fi

  prepare_sudo
  info "ngắt OpenVPN PID $pid"
  run_root kill -TERM "$pid" 2>/dev/null || true
  local i
  for i in {1..10}; do
    proc_exists "$pid" || break
    sleep 1
  done
  if proc_exists "$pid"; then
    warn "OpenVPN chưa dừng sau 10 giây; không tự kill -9"
    return 1
  fi
  rm -f "$(openvpn_pidfile)" 2>/dev/null || true
  return 0
}

# Các PID OpenVPN đang chạy nhưng không phải process do ocx quản lý.
unmanaged_openvpn_pids() {
  local d pid comm cmd managed_pid
  managed_pid="$(openvpn_pid 2>/dev/null || true)"
  for d in /proc/[0-9]*; do
    pid="${d##*/}"
    [[ "$pid" == "$managed_pid" ]] && continue
    [[ -r "$d/comm" ]] || continue
    comm="$(<"$d/comm")"
    [[ "$comm" == "openvpn" ]] || continue
    cmd="$(proc_cmdline "$pid" 2>/dev/null || true)"
    [[ -n "$cmd" ]] || continue
    printf '%s\n' "$pid"
  done
}

openvpn_disconnect_all() {
  local d pid cmd comm found=0
  for d in /proc/[0-9]*; do
    pid="${d##*/}"
    [[ -r "$d/comm" ]] || continue
    comm="$(<"$d/comm")"
    [[ "$comm" == "openvpn" ]] || continue
    cmd="$(proc_cmdline "$pid" 2>/dev/null || true)"
    [[ "$cmd" == *openvpn* && "$cmd" == *"$OCX_VPN_DIR"* ]] || continue
    found=1
    prepare_sudo
    info "ngắt OpenVPN không còn trong state: PID $pid"
    run_root kill -TERM "$pid" 2>/dev/null || true
  done
  if (( found == 0 )); then
    info "không tìm thấy OpenVPN nào dùng profile trong $OCX_VPN_DIR"
  fi
  rm -f "$(openvpn_pidfile)" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# WireGuard
# ---------------------------------------------------------------------------
wg_iface_name() { basename "${1%.conf}"; }

wg_iface_up() {
  local iface="$1"
  have_cmd "$IP_BIN" || return 1
  "$IP_BIN" link show dev "$iface" >/dev/null 2>&1
}

wg_connect() {
  local path="$1" name="$2" iface
  require_cmd "$WG_QUICK_BIN"
  iface="$(wg_iface_name "$path")"
  prepare_sudo
  if wg_iface_up "$iface"; then
    warn "interface $iface đang tồn tại; hạ trước khi nối lại"
    run_root "$WG_QUICK_BIN" down "$path" >/dev/null 2>&1 || true
  fi
  info "khởi động WireGuard: $name ($iface)"
  if ! run_root "$WG_QUICK_BIN" up "$path"; then
    warn "wg-quick không khởi động được profile $name"
    return 1
  fi
  return 0
}

wg_disconnect() {
  local path="${ACTIVE_PATH:-}" iface="${ACTIVE_IFACE:-}" name="${ACTIVE_PROFILE:-}"
  if [[ -z "$path" && -n "$iface" ]]; then
    path="$OCX_WG_DIR/$iface.conf"
  fi
  [[ -n "$iface" ]] || { [[ -n "$path" ]] && iface="$(wg_iface_name "$path")"; }
  if [[ -z "$path" || ! -f "$path" ]]; then
    [[ -n "$iface" ]] || return 0
    wg_iface_up "$iface" || return 0
    require_cmd "$WG_QUICK_BIN"
    prepare_sudo
    info "ngắt WireGuard: ${name:-$iface} ($iface)"
    run_root "$WG_QUICK_BIN" down "$iface"
    return
  fi
  wg_iface_up "$iface" || return 0
  require_cmd "$WG_QUICK_BIN"
  prepare_sudo
  info "ngắt WireGuard: ${name:-$iface} ($iface)"
  run_root "$WG_QUICK_BIN" down "$path" || run_root "$WG_QUICK_BIN" down "$iface"
}

wg_disconnect_all() {
  local file iface
  while IFS= read -r -d '' file; do
    iface="$(wg_iface_name "$file")"
    wg_iface_up "$iface" || continue
    prepare_sudo
    info "ngắt WireGuard: $file ($iface)"
    run_root "$WG_QUICK_BIN" down "$file" >/dev/null 2>&1 || true
  done < <(find "$OCX_WG_DIR" -type f -name '*.conf' -print0 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Generic connect / disconnect / health verification
# ---------------------------------------------------------------------------
disconnect_current() {
  state_load
  case "${ACTIVE_BACKEND:-}" in
    openvpn)   openvpn_disconnect ;;
    wireguard) wg_disconnect ;;
    "")
      # State có thể bị mất nhưng pidfile vẫn còn process do ocx khởi động.
      if openvpn_alive; then openvpn_disconnect; else return 0; fi
      ;;
    *)         warn "backend không rõ trong state: $ACTIVE_BACKEND"; return 1 ;;
  esac
}

# Wait until the tunnel reports ready, then until a public IPv4 is available.
# Sets CONNECTED_IP on success.
CONNECTED_IP=""
wait_connected() {
  local backend="$1" name="$2" path="$3" old_ip="${4:-}"
  local deadline logfile iface ip i
  deadline=$(( $(now_epoch) + OCX_CONNECT_TIMEOUT ))
  logfile="$(openvpn_logfile "$name")"
  iface="$(wg_iface_name "$path")"

  while (( $(now_epoch) < deadline )); do
    case "$backend" in
      openvpn)
        if ! openvpn_alive; then
          warn "OpenVPN đã dừng trước khi sẵn sàng"
          tail -n 40 "$logfile" 2>/dev/null >&2 || true
          return 1
        fi
        if [[ -r "$logfile" ]]; then
          if grep -qE 'Initialization Sequence Completed' "$logfile" 2>/dev/null; then
            break
          fi
          if grep -qE 'ERROR:|Exiting due to fatal error|AUTH_FAILED' "$logfile" 2>/dev/null; then
            warn "OpenVPN báo lỗi; log: $logfile"
            tail -n 40 "$logfile" 2>/dev/null >&2 || true
            return 1
          fi
        fi
        ;;
      wireguard)
        if wg_iface_up "$iface"; then break; fi
        ;;
      *)
        warn "backend không hỗ trợ: $backend"; return 1 ;;
    esac
    sleep 1
  done

  case "$backend" in
    openvpn) openvpn_alive || { warn "OpenVPN không còn chạy"; return 1; } ;;
    wireguard) wg_iface_up "$iface" || { warn "WireGuard interface $iface không lên"; return 1; } ;;
  esac

  ip=""
  deadline=$(( $(now_epoch) + OCX_IP_TIMEOUT ))
  while (( $(now_epoch) < deadline )); do
    ip="$(fetch_ip 2>/dev/null || true)"
    [[ -n "$ip" ]] && break
    sleep 1
  done
  if [[ -z "$ip" ]]; then
    warn "tunnel đã lên nhưng không lấy được IPv4 public sau ${OCX_IP_TIMEOUT}s"
    return 1
  fi

  CONNECTED_IP="$ip"
  if [[ -n "$old_ip" && "$ip" == "$old_ip" ]]; then
    warn "IP public không đổi ($ip). Có thể VPN chưa route traffic hoặc profile trùng đầu ra."
    if truthy "$OCX_REQUIRE_IP_CHANGE"; then
      return 1
    fi
  fi
  return 0
}

# Connect one profile line. Returns 0 on success and saves state.
connect_entry() {
  local entry="$1" backend name path region old_ip
  IFS=$'\t' read -r backend name path region <<< "$entry"
  [[ -f "$path" ]] || { warn "không thấy file profile: $path"; return 1; }

  old_ip="$(fetch_ip 2>/dev/null || true)"
  info "ngắt kết nối cũ (nếu có)"
  if ! disconnect_current; then
    warn "không ngắt được kết nối cũ; dừng để tránh chồng tunnel"
    return 1
  fi
  state_clear

  if truthy "$OCX_CHECK_UNMANAGED_VPN"; then
    local -a unmanaged=()
    mapfile -t unmanaged < <(unmanaged_openvpn_pids)
    if ((${#unmanaged[@]} > 0)); then
      warn "phát hiện OpenVPN không do ocx quản lý: PID ${unmanaged[*]}"
      warn "hãy dừng VPN đó trước (Ctrl-C ở terminal đang chạy, hoặc kill PID) rồi thử lại"
      warn "ocx không tự kill process OpenVPN ngoài state/pidfile của nó"
      return 1
    fi
  fi

  # Lưu state tạm để nếu health check thất bại vẫn ngắt được đúng process.
  ACTIVE_BACKEND="$backend"
  ACTIVE_PROFILE="$name"
  ACTIVE_PATH="$path"
  ACTIVE_PID=""
  ACTIVE_PID_START=""
  ACTIVE_IFACE=""
  [[ "$backend" == wireguard ]] && ACTIVE_IFACE="$(wg_iface_name "$path")"
  ACTIVE_IP=""
  ACTIVE_SINCE="$(now_epoch)"
  state_save

  local rc=0
  case "$backend" in
    openvpn)   openvpn_connect "$path" "$name" || rc=$? ;;
    wireguard) wg_connect "$path" "$name" || rc=$? ;;
    *) warn "backend không hỗ trợ: $backend"; rc=1 ;;
  esac
  if (( rc != 0 )); then
    health_record "fail" "$name" "" "backend start failed"
    disconnect_current >/dev/null 2>&1 || true
    state_clear
    return 1
  fi

  if [[ "$backend" == openvpn ]]; then
    ACTIVE_PID="$(openvpn_pid 2>/dev/null || true)"
    if [[ -n "$ACTIVE_PID" ]]; then
      ACTIVE_PID_START="$(proc_start_ticks "$ACTIVE_PID" 2>/dev/null || true)"
    fi
    state_save
  fi

  if ! wait_connected "$backend" "$name" "$path" "$old_ip"; then
    health_record "fail" "$name" "" "health check failed"
    disconnect_current >/dev/null 2>&1 || true
    state_clear
    return 1
  fi

  ACTIVE_IP="$CONNECTED_IP"
  ACTIVE_SINCE="$(now_epoch)"
  state_save

  health_record "ok" "$name" "$CONNECTED_IP" "connected"
  ok "đã kết nối $backend/$name"
  printf 'IPv4 public: %s\n' "$CONNECTED_IP"
  if [[ -n "$old_ip" && "$old_ip" != "$CONNECTED_IP" ]]; then
    printf 'IP trước đó: %s\n' "$old_ip"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Rotation
# ---------------------------------------------------------------------------
# connect_sequence REGION BACKEND START_NAME MODE [FAILOVER]
#   MODE: next | use | random | auto
#   START_NAME is required for "use" and optional for others.
connect_sequence() {
  local region="${1:-}" backend="${2:-}" start_name="${3:-}" mode="${4:-next}" \
        failover="${5:-1}"
  local -a entries=()
  mapfile -t entries < <(list_profiles "$region" "$backend")
  local n=${#entries[@]}
  (( n > 0 )) || { warn "không có profile VPN phù hợp"; return 1; }

  local current="" idx=-1 i name
  state_load
  current="${ACTIVE_PROFILE:-}"
  for ((i = 0; i < n; i++)); do
    name="$(cut -f2 <<< "${entries[$i]}")"
    if [[ "$mode" == "use" && "$name" == "$start_name" ]]; then
      idx=$i; break
    fi
    if [[ "$mode" == "next" && -n "$current" && "$name" == "$current" ]]; then
      idx=$i
    fi
  done

  case "$mode" in
    use)
      (( idx >= 0 )) || { warn "không tìm thấy profile '$start_name' trong danh sách"; return 1; }
      ;;
    next)
      if (( idx >= 0 )); then idx=$(( (idx + 1) % n )); else idx=0; fi
      ;;
    random)
      idx=$(( RANDOM % n ))
      ;;
    auto)
      idx=0
      ;;
    *)
      warn "mode rotation không hợp lệ: $mode"; return 1 ;;
  esac

  local limit="$n"
  truthy "$failover" || limit=1
  local tried entry rc
  for ((tried = 0; tried < limit; tried++)); do
    entry="${entries[$(( (idx + tried) % n ))]}"
    IFS=$'\t' read -r backend name _ _ <<< "$entry"
    info "thử $backend/$name ($((tried + 1))/$limit)"
    rc=0
    connect_entry "$entry" || rc=$?
    if (( rc == 0 )); then
      return 0
    fi
    warn "profile $name thất bại; thử profile tiếp theo nếu còn"
  done
  warn "tất cả profile đã thử đều thất bại"
  return 1
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
vpn_list() {
  local region="" backend="" current=""
  while (($#)); do
    case "$1" in
      --region) region="$(normalize_region "${2:-}")"; shift 2 ;;
      --backend) backend="${2:-}"; shift 2 ;;
      -h|--help) usage_vpn; return 0 ;;
      *) die "tham số không hợp lệ cho vpn list: $1" ;;
    esac
  done
  state_load
  current="${ACTIVE_PROFILE:-}"

  local -a all_entries=() entries=()
  mapfile -t all_entries < <(list_profiles)
  mapfile -t entries < <(list_profiles "$region" "$backend")

  # Số thứ tự luôn theo danh sách đầy đủ, để `ocx vpn use <số>` ổn định
  # kể cả khi đang xem danh sách đã lọc.
  local -A index_of=()
  local entry b n p r mark health okflag ip ts msg age idx key i=0
  for entry in "${all_entries[@]}"; do
    i=$((i + 1))
    IFS=$'\t' read -r b n _ _ <<< "$entry"
    index_of["$b|$n"]="$i"
  done

  if ((${#entries[@]} == 0)); then
    printf 'Chưa có profile phù hợp.\n'
    printf 'Import profile, ví dụ:\n'
    printf '  ocx vpn import ~/Workspace/test/vpn_vn --region vn\n'
    printf '  ocx vpn import ~/Workspace/test/japan --region jp\n'
    return 0
  fi

  printf '%-3s %-2s %-6s %-9s %-50s %-10s %s\n' "#" "" "VÙNG" "BACKEND" "PROFILE" "HEALTH" "IP GẦN NHẤT"
  for entry in "${entries[@]}"; do
    IFS=$'\t' read -r b n p r <<< "$entry"
    key="$b|$n"
    idx="${index_of[$key]:-0}"
    mark=" "
    [[ "$n" == "$current" ]] && mark="*"
    health="$(health_lookup "$n" 2>/dev/null || true)"
    if [[ -n "$health" ]]; then
      IFS=$'\t' read -r ts okflag _ ip msg <<< "$health"
      age="$(human_age "$ts")"
      [[ "$okflag" == ok ]] && health="ok/${age}" || health="fail/${age}"
    else
      ip="-"; health="-"
    fi
    [[ -n "$ip" ]] || ip="-"
    printf '%-3s %-2s %-6s %-9s %-50s %-10s %s\n' "$idx" "$mark" "$r" "$b" "$n" "$health" "$ip"
  done
  printf '\nTổng: %d profile. (* = đang kết nối)\n' "${#entries[@]}"
  printf 'Chọn nhanh theo số: ocx vpn use <số>\n'
}

vpn_regions() {
  local r n
  printf 'Vùng   Số profile\n'
  list_profiles | cut -f4 | sort | uniq -c | while read -r n r; do
    printf '%-6s %s\n' "$r" "$n"
  done
}

vpn_import() {
  local region_override="" name_override="" force=0
  local -a sources=()
  while (($#)); do
    case "$1" in
      --region) region_override="$(normalize_region "${2:-}")"; shift 2 ;;
      --name) name_override="${2:-}"; shift 2 ;;
      --force|-f) force=1; shift ;;
      -h|--help) usage_vpn; return 0 ;;
      *) sources+=("$1"); shift ;;
    esac
  done
  ((${#sources[@]} > 0)) || die "cách dùng: ocx vpn import <file|dir>... [--region R] [--name NAME] [--force]"
  (( ${#sources[@]} == 1 )) || [[ -z "$name_override" ]] \
    || die "--name chỉ dùng được khi import một file"

  local -a files=()
  local src f
  for src in "${sources[@]}"; do
    [[ -e "$src" ]] || { warn "không tồn tại: $src"; continue; }
    if [[ -d "$src" ]]; then
      while IFS= read -r -d '' f; do files+=("$f"); done \
        < <(find "$src" -type f \( -name '*.ovpn' -o -name '*.conf' \) -print0 2>/dev/null)
    else
      files+=("$src")
    fi
  done
  ((${#files[@]} > 0)) || die "không tìm thấy file .ovpn hoặc .conf"

  local file base ext backend destdir dest region srcdir
  local imported=0
  for file in "${files[@]}"; do
    ext="$(lower "${file##*.}")"
    case "$ext" in
      ovpn) backend=openvpn ;;
      conf) backend=wireguard ;;
      *) warn "bỏ qua phần mở rộng không hỗ trợ: $file"; continue ;;
    esac
    base="$(basename "$file")"
    base="${base%.*}"
    [[ "$base" != *"|"* && "$base" != *"/"* ]] \
      || die "tên file không được chứa '|' hoặc '/': $file"

    if [[ -n "$region_override" ]]; then
      region="$region_override"
    else
      srcdir="$(dirname "$file")"
      region="$(normalize_region "$(basename "$srcdir")")"
      case "$region" in
        vn|jp|us|sg|kr|tw|hk|th|my|id|ph|gb|de|fr|nl|ca|au|in|ru|ae) ;;
        # Tên thư mục không phải vùng đã biết: thử suy ra từ tên file.
        *) region="$(region_from_filename "$base")" ;;
      esac
    fi
    [[ -n "$region" ]] || region="misc"
    [[ "$region" != *"/"* && "$region" != "." && "$region" != ".." ]] \
      || die "vùng không hợp lệ: $region"

    if [[ -n "$name_override" ]]; then
      base="$name_override"
    fi
    [[ -n "$base" ]] || die "tên profile rỗng: $file"
    [[ "$base" != *"/"* && "$base" != *"|"* && "$base" != "." && "$base" != ".." ]] \
      || die "tên profile không hợp lệ: $base"

    if [[ "$backend" == openvpn ]]; then
      destdir="$OCX_VPN_DIR/$region"
    else
      destdir="$OCX_WG_DIR/$region"
    fi
    mkdir -p "$destdir"
    dest="$destdir/$base.$ext"
    if [[ -e "$dest" ]]; then
      if [[ "$file" -ef "$dest" ]] || cmp -s "$file" "$dest"; then
        info "đã có, bỏ qua: $dest"
        continue
      fi
      if ! truthy "$force"; then
        warn "đã tồn tại: $dest (dùng --force để ghi đè)"
        continue
      fi
    fi
    install -m 600 -- "$file" "$dest"
    imported=$((imported + 1))
    printf 'Đã import: %s (%s/%s)\n' "$dest" "$backend" "$region"
  done
  printf 'Đã import %d profile. Xem bằng: ocx vpn list\n' "$imported"
}

vpn_use() {
  local query="" failover="$OCX_FAILOVER" require_new="$OCX_REQUIRE_IP_CHANGE"
  while (($#)); do
    case "$1" in
      --failover) failover=1; shift ;;
      --no-failover) failover=0; shift ;;
      --require-new-ip) require_new=1; shift ;;
      -h|--help) usage_vpn; return 0 ;;
      *) query="$1"; shift ;;
    esac
  done
  [[ -n "$query" ]] || die "cách dùng: ocx vpn use <profile> [--failover] [--require-new-ip]"
  local entry
  entry="$(profile_resolve "$query")" || return $?
  [[ -n "$entry" ]] || return 1
  OCX_REQUIRE_IP_CHANGE="$require_new"
  local backend name path region
  IFS=$'\t' read -r backend name path region <<< "$entry"
  if truthy "$failover"; then
    connect_sequence "$region" "$backend" "$name" "use" 1
  else
    connect_entry "$entry"
  fi
}

vpn_next() {
  local region="" backend="" mode="next" failover="$OCX_FAILOVER"
  while (($#)); do
    case "$1" in
      --region) region="$(normalize_region "${2:-}")"; shift 2 ;;
      --backend) backend="${2:-}"; shift 2 ;;
      --random) mode="random"; shift ;;
      --no-failover) failover=0; shift ;;
      --failover) failover=1; shift ;;
      -h|--help) usage_vpn; return 0 ;;
      *) die "tham số không hợp lệ cho vpn next: $1" ;;
    esac
  done
  [[ -n "$mode" ]] || mode="next"
  connect_sequence "$region" "$backend" "" "$mode" "$failover"
}

vpn_random() {
  local region="" backend=""
  while (($#)); do
    case "$1" in
      --region) region="$(normalize_region "${2:-}")"; shift 2 ;;
      --backend) backend="${2:-}"; shift 2 ;;
      -h|--help) usage_vpn; return 0 ;;
      *) die "tham số không hợp lệ cho vpn random: $1" ;;
    esac
  done
  connect_sequence "$region" "$backend" "" "random" 1
}

vpn_region() {
  local region raw="${1:-}"
  [[ -n "$raw" && "$raw" != -* ]] \
    || die "cách dùng: ocx vpn region <vn|jp|us|...> [--no-failover] [--backend ...]"
  region="$(normalize_region "$raw")"
  [[ -n "$region" ]] || die "vùng không hợp lệ: $raw"
  shift
  local failover="$OCX_FAILOVER" backend=""
  while (($#)); do
    case "$1" in
      --no-failover) failover=0; shift ;;
      --failover) failover=1; shift ;;
      --backend) backend="${2:-}"; shift 2 ;;
      *) die "tham số không hợp lệ cho vpn region: $1" ;;
    esac
  done
  connect_sequence "$region" "$backend" "" "next" "$failover"
}

vpn_auto() {
  local region="" backend="" failover="$OCX_FAILOVER"
  while (($#)); do
    case "$1" in
      --region) region="$(normalize_region "${2:-}")"; shift 2 ;;
      --backend) backend="${2:-}"; shift 2 ;;
      --no-failover) failover=0; shift ;;
      *) die "tham số không hợp lệ cho vpn auto: $1" ;;
    esac
  done
  connect_sequence "$region" "$backend" "" "auto" "$failover"
}

vpn_test() {
  local query="" keep=0
  while (($#)); do
    case "$1" in
      --keep) keep=1; shift ;;
      -h|--help) usage_vpn; return 0 ;;
      *) query="$1"; shift ;;
    esac
  done
  [[ -n "$query" ]] || die "cách dùng: ocx vpn test <profile> [--keep]"
  local entry
  entry="$(profile_resolve "$query")" || return $?
  [[ -n "$entry" ]] || return 1
  local rc=0
  connect_entry "$entry" || rc=$?
  if (( keep == 0 )); then
    if [[ -n "${ACTIVE_BACKEND:-}" ]] || openvpn_alive; then
      info "ngắt sau khi test (dùng --keep để giữ kết nối)"
    fi
    disconnect_current >/dev/null 2>&1 || true
    state_clear
  fi
  return "$rc"
}

vpn_status() {
  state_load
  local ip
  ip="$(fetch_ip 2>/dev/null || true)"
  if [[ -n "$ip" ]]; then
    printf 'IPv4 public hiện tại: %s\n' "$ip"
  else
    printf 'Không lấy được IPv4 public (mạng hoặc endpoint kiểm tra lỗi).\n'
  fi

  if [[ -z "${ACTIVE_BACKEND:-}" ]]; then
    printf 'Không có tunnel nào do ocx quản lý.\n'
    local pid
    pid="$(openvpn_pid 2>/dev/null || true)"
    if proc_exists "$pid"; then
      printf 'Có PID OpenVPN trong pidfile nhưng không có state: %s\n' "$pid"
    fi
    return 0
  fi

  printf '\nBackend:      %s\n' "$ACTIVE_BACKEND"
  printf 'Profile:      %s\n' "$ACTIVE_PROFILE"
  printf 'Vùng:         %s\n' "$(region_from_path "$ACTIVE_PATH" 2>/dev/null || printf '?')"
  printf 'File:         %s\n' "$ACTIVE_PATH"
  printf 'IP lúc nối:   %s\n' "${ACTIVE_IP:--}"
  printf 'Từ lúc:       %s (%s trước)\n' \
    "$(date -d "@${ACTIVE_SINCE:-0}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "${ACTIVE_SINCE:-?}")" \
    "$(human_age "${ACTIVE_SINCE:-0}")"

  case "$ACTIVE_BACKEND" in
    openvpn)
      printf 'PID:          %s\n' "${ACTIVE_PID:--}"
      if openvpn_alive; then
        printf 'Trạng thái:   OpenVPN đang chạy\n'
      else
        printf 'Trạng thái:   OpenVPN KHÔNG chạy (state cũ?)\n'
      fi
      printf 'Log:          %s\n' "$(openvpn_logfile "$ACTIVE_PROFILE")"
      ;;
    wireguard)
      printf 'Interface:    %s\n' "${ACTIVE_IFACE:--}"
      if wg_iface_up "${ACTIVE_IFACE:-}"; then
        printf 'Trạng thái:   WireGuard đang lên\n'
      else
        printf 'Trạng thái:   WireGuard KHÔNG lên\n'
      fi
      ;;
  esac

  local h
  h="$(health_lookup "$ACTIVE_PROFILE" 2>/dev/null || true)"
  if [[ -n "$h" ]]; then
    local ts okflag _ hip msg
    IFS=$'\t' read -r ts okflag _ hip msg <<< "$h"
    printf 'Health:       %s %s (%s trước) %s\n' "$okflag" "$hip" "$(human_age "$ts")" "$msg"
  fi
}

vpn_disconnect() {
  local all=0
  while (($#)); do
    case "$1" in
      --all|-a) all=1; shift ;;
      -h|--help) usage_vpn; return 0 ;;
      *) die "tham số không hợp lệ cho vpn disconnect: $1" ;;
    esac
  done
  local rc=0
  disconnect_current || rc=$?
  if truthy "$all"; then
    openvpn_disconnect_all
    wg_disconnect_all
  fi
  if (( rc == 0 )); then
    state_clear
    info "đã ngắt tunnel do ocx quản lý"
  else
    warn "chưa ngắt được tunnel; giữ state để bạn kiểm tra"
  fi
  return "$rc"
}

vpn_log() {
  local lines="${1:-80}"
  [[ "$lines" =~ ^[0-9]+$ ]] || die "số dòng phải là số"
  state_load
  if [[ "$ACTIVE_BACKEND" == openvpn && -n "$ACTIVE_PROFILE" ]]; then
    local logfile
    logfile="$(openvpn_logfile "$ACTIVE_PROFILE")"
    [[ -f "$logfile" ]] || die "chưa có log: $logfile"
    if [[ -r "$logfile" ]]; then tail -n "$lines" "$logfile"
    else prepare_sudo; run_root tail -n "$lines" "$logfile"
    fi
    return 0
  fi
  printf 'Các log OpenVPN gần đây trong %s:\n' "$OCX_LOG_DIR"
  find "$OCX_LOG_DIR" -maxdepth 1 -type f -name 'openvpn-*.log' -printf '%f\n' 2>/dev/null | sort | tail -n 20
}

vpn_help() { usage_vpn; }
