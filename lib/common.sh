#!/usr/bin/env bash
# ocx — common helpers, configuration, state, diagnostics.

APP="ocx"
VERSION="0.2.0"

# ---------------------------------------------------------------------------
# Paths (override with environment variables when testing or integrating)
# ---------------------------------------------------------------------------
OCX_CONFIG_DIR="${OCX_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ocx}"
OCX_CACHE_DIR="${OCX_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ocx}"
OCX_STATE_DIR="${OCX_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ocx}"
OCX_CONFIG_FILE="${OCX_CONFIG_FILE:-$OCX_CONFIG_DIR/ocx.conf}"
OCX_MODELS_FILE="${OCX_MODELS_FILE:-$OCX_CONFIG_DIR/models.conf}"
OCX_VPN_DIR="${OCX_VPN_DIR:-$OCX_CONFIG_DIR/vpn}"
OCX_WG_DIR="${OCX_WG_DIR:-$OCX_CONFIG_DIR/wireguard}"
OCX_LOG_DIR="${OCX_LOG_DIR:-$OCX_CACHE_DIR/log}"
OCX_STATE_FILE="${OCX_STATE_FILE:-$OCX_STATE_DIR/vpn.state}"
OCX_HEALTH_FILE="${OCX_HEALTH_FILE:-$OCX_STATE_DIR/vpn-health.tsv}"
OCX_MODELS_CACHE="${OCX_MODELS_CACHE:-$OCX_CACHE_DIR/opencode-models.txt}"
OCX_LOCK_FILE="${OCX_LOCK_FILE:-$OCX_CACHE_DIR/ocx.lock}"
OCX_OPENVPN_PID_FILE="${OCX_OPENVPN_PID_FILE:-$OCX_CACHE_DIR/openvpn.pid}"

OPENCODE_BIN="${OCX_OPENCODE_BIN:-opencode}"
OPENVPN_BIN="${OCX_OPENVPN_BIN:-openvpn}"
WG_BIN="${OCX_WG_BIN:-wg}"
WG_QUICK_BIN="${OCX_WG_QUICK_BIN:-wg-quick}"
CURL_BIN="${OCX_CURL_BIN:-curl}"
SUDO_BIN="${OCX_SUDO_BIN:-sudo}"
JQ_BIN="${OCX_JQ_BIN:-jq}"
IP_BIN="${OCX_IP_BIN:-ip}"
SHUF_BIN="${OCX_SHUF_BIN:-shuf}"

# ---------------------------------------------------------------------------
# Defaults. ocx.conf is sourced after this, so user values win.
# ---------------------------------------------------------------------------
OCX_CONNECT_TIMEOUT="${OCX_CONNECT_TIMEOUT:-60}"
OCX_IP_TIMEOUT="${OCX_IP_TIMEOUT:-30}"
OCX_SUDO="${OCX_SUDO:-ask}"              # ask | none
OCX_SUDO_NONINTERACTIVE="${OCX_SUDO_NONINTERACTIVE:-0}"
OCX_FAILOVER="${OCX_FAILOVER:-1}"
OCX_REQUIRE_IP_CHANGE="${OCX_REQUIRE_IP_CHANGE:-0}"
OCX_ROTATE_MODE="${OCX_ROTATE_MODE:-next}" # next | random | auto
OCX_MODELS_CACHE_TTL="${OCX_MODELS_CACHE_TTL:-300}"
OCX_RUN_FALLBACK_ON_RATE_LIMIT="${OCX_RUN_FALLBACK_ON_RATE_LIMIT:-0}"
# Xoay VPN khi gặp đúng lỗi "Free usage limit reached" trong `ocx run`.
# Mặc định tắt; bật bằng --vpn-rotate hoặc đặt biến này =1.
OCX_RUN_VPN_ON_FREE_LIMIT="${OCX_RUN_VPN_ON_FREE_LIMIT:-0}"
# Region dùng khi xoay VPN; để trống = giữ region hiện tại.
OCX_RUN_VPN_REGION="${OCX_RUN_VPN_REGION:-}"
# Số lần thử xoay VPN tối đa trong một lần `ocx run`; 0 = không giới hạn.
OCX_RUN_VPN_MAX="${OCX_RUN_VPN_MAX:-20}"
# Timeout cho mỗi lần kết nối/kiểm tra IP VPN khi xoay (giây).
OCX_RUN_VPN_TIMEOUT="${OCX_RUN_VPN_TIMEOUT:-30}"
# Timeout cho mỗi lần gọi `opencode run` (giây); 0 = tắt timeout.
OCX_RUN_TIMEOUT="${OCX_RUN_TIMEOUT:-180}"
OCX_HEALTH_KEEP="${OCX_HEALTH_KEEP:-500}"
# Cảnh báo/không nối nếu có OpenVPN không do ocx quản lý đang chạy.
OCX_CHECK_UNMANAGED_VPN="${OCX_CHECK_UNMANAGED_VPN:-1}"

declare -p OCX_HEALTH_URLS >/dev/null 2>&1 || OCX_HEALTH_URLS=()
if [[ ${#OCX_HEALTH_URLS[@]} -eq 0 ]]; then
  OCX_HEALTH_URLS=(
    "https://api.ipify.org"
    "https://ifconfig.me/ip"
    "https://icanhazip.com"
    "https://ipinfo.io/ip"
  )
fi

ROOT_CMD=()

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
die()  { printf 'ocx: lỗi: %s\n' "$*" >&2; exit 1; }
warn() { printf 'ocx: cảnh báo: %s\n' "$*" >&2; }
info() { printf 'ocx: %s\n' "$*"; }
ok()   { printf 'ocx: OK: %s\n' "$*"; }

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

safe_name() {
  local s="${1:-profile}"
  s="${s//\//__}"
  s="${s// /_}"
  s="$(printf '%s' "$s" | tr -c 'A-Za-z0-9._-' '_')"
  printf '%s' "${s:-profile}"
}

now_epoch() { date +%s; }

human_age() {
  local ts="${1:-0}" now diff
  [[ "$ts" =~ ^[0-9]+$ ]] || { printf -- '-'; return; }
  now="$(now_epoch)"
  diff=$((now - ts))
  ((diff < 0)) && diff=0
  if ((diff < 60)); then printf '%ss' "$diff"
  elif ((diff < 3600)); then printf '%sm' "$((diff / 60))"
  elif ((diff < 86400)); then printf '%sh' "$((diff / 3600))"
  else printf '%sd' "$((diff / 86400))"
  fi
}

# ---------------------------------------------------------------------------
# Bootstrap and config
# ---------------------------------------------------------------------------
ensure_dirs() {
  mkdir -p "$OCX_CONFIG_DIR" "$OCX_CACHE_DIR" "$OCX_STATE_DIR" \
           "$OCX_VPN_DIR" "$OCX_WG_DIR" "$OCX_LOG_DIR"
  chmod 700 "$OCX_CONFIG_DIR" "$OCX_CACHE_DIR" "$OCX_STATE_DIR" \
           "$OCX_VPN_DIR" "$OCX_WG_DIR" "$OCX_LOG_DIR" 2>/dev/null || true
}

load_config() {
  ensure_dirs
  if [[ -f "$OCX_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$OCX_CONFIG_FILE"
  fi
  # Re-apply directory defaults in case config changed them.
  OCX_VPN_DIR="${OCX_VPN_DIR:-$OCX_CONFIG_DIR/vpn}"
  OCX_WG_DIR="${OCX_WG_DIR:-$OCX_CONFIG_DIR/wireguard}"
  OCX_LOG_DIR="${OCX_LOG_DIR:-$OCX_CACHE_DIR/log}"
  mkdir -p "$OCX_VPN_DIR" "$OCX_WG_DIR" "$OCX_LOG_DIR"
  chmod 700 "$OCX_VPN_DIR" "$OCX_WG_DIR" "$OCX_LOG_DIR" 2>/dev/null || true
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "không tìm thấy lệnh '$1'. Cài đặt rồi thử lại."
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# sudo abstraction. Tests can set OCX_SUDO_BIN to a mock.
# ---------------------------------------------------------------------------
prepare_sudo() {
  case "${OCX_SUDO:-ask}" in
    none|NONE|off|OFF)
      ROOT_CMD=()
      ;;
    ask|ASK|on|ON|1|true|TRUE)
      ROOT_CMD=("$SUDO_BIN")
      if ! truthy "$OCX_SUDO_NONINTERACTIVE"; then
        "${ROOT_CMD[@]}" -v || die "không lấy được quyền sudo"
      fi
      ;;
    *)
      die "OCX_SUDO phải là 'ask' hoặc 'none' (đang là '$OCX_SUDO')"
      ;;
  esac
}

run_root() {
  if ((${#ROOT_CMD[@]} > 0)); then
    "${ROOT_CMD[@]}" "$@"
  else
    "$@"
  fi
}

read_file_root() {
  local f="$1"
  if [[ -r "$f" ]]; then cat "$f"; else run_root cat "$f"; fi
}

# ---------------------------------------------------------------------------
# State: one active tunnel managed by ocx.
# Fields are pipe-separated and written atomically.
# ---------------------------------------------------------------------------
ACTIVE_BACKEND=""
ACTIVE_PROFILE=""
ACTIVE_PATH=""
ACTIVE_PID=""
ACTIVE_PID_START=""
ACTIVE_IFACE=""
ACTIVE_IP=""
ACTIVE_SINCE=""

state_load() {
  ACTIVE_BACKEND=""; ACTIVE_PROFILE=""; ACTIVE_PATH=""; ACTIVE_PID=""
  ACTIVE_PID_START=""; ACTIVE_IFACE=""; ACTIVE_IP=""; ACTIVE_SINCE=""
  [[ -s "$OCX_STATE_FILE" ]] || return 0
  local line
  IFS= read -r line < "$OCX_STATE_FILE" || return 0
  IFS='|' read -r ACTIVE_BACKEND ACTIVE_PROFILE ACTIVE_PATH ACTIVE_PID \
    ACTIVE_PID_START ACTIVE_IFACE ACTIVE_IP ACTIVE_SINCE <<< "$line"
}

state_save() {
  local tmp="$OCX_STATE_FILE.tmp.$$"
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$ACTIVE_BACKEND" "$ACTIVE_PROFILE" "$ACTIVE_PATH" "$ACTIVE_PID" \
    "$ACTIVE_PID_START" "$ACTIVE_IFACE" "$ACTIVE_IP" "$ACTIVE_SINCE" > "$tmp"
  mv -f "$tmp" "$OCX_STATE_FILE"
}

state_clear() {
  rm -f "$OCX_STATE_FILE"
  ACTIVE_BACKEND=""; ACTIVE_PROFILE=""; ACTIVE_PATH=""; ACTIVE_PID=""
  ACTIVE_PID_START=""; ACTIVE_IFACE=""; ACTIVE_IP=""; ACTIVE_SINCE=""
}

with_lock() {
  if have_cmd flock; then
    exec 9>"$OCX_LOCK_FILE" || die "không mở được lock file"
    flock -w 30 9 || die "không lấy được lock sau 30 giây"
  fi
  local rc=0
  if "$@"; then
    rc=0
  else
    rc=$?
  fi
  if have_cmd flock; then flock -u 9 2>/dev/null || true; fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# Health history
# ---------------------------------------------------------------------------
health_record() {
  local okflag="$1" profile="$2" ip="$3" msg="${4:-}"
  mkdir -p "$(dirname "$OCX_HEALTH_FILE")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(now_epoch)" "$okflag" "$profile" "$ip" "$msg" \
    >> "$OCX_HEALTH_FILE" 2>/dev/null || return 0
  local n
  n=$(wc -l < "$OCX_HEALTH_FILE" 2>/dev/null || printf 0)
  if (( n > OCX_HEALTH_KEEP )); then
    tail -n "$OCX_HEALTH_KEEP" "$OCX_HEALTH_FILE" > "$OCX_HEALTH_FILE.tmp.$$" \
      && mv -f "$OCX_HEALTH_FILE.tmp.$$" "$OCX_HEALTH_FILE"
  fi
}

# Prints: ok<TAB>ip<TAB>timestamp<TAB>message
health_lookup() {
  local profile="$1"
  [[ -s "$OCX_HEALTH_FILE" ]] || return 1
  awk -F'\t' -v p="$profile" '$3 == p { line = $0 } END { if (line != "") print line }' \
    "$OCX_HEALTH_FILE"
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
is_ipv4() {
  [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=. part
  for part in $1; do
    ((part >= 0 && part <= 255)) || return 1
  done
  return 0
}

proc_exists() { [[ "${1:-}" =~ ^[0-9]+$ && -d "/proc/$1" ]]; }

proc_cmdline() {
  local pid="$1"
  [[ -r "/proc/$pid/cmdline" ]] || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null
}

proc_start_ticks() {
  local pid="$1"
  [[ -r "/proc/$pid/stat" ]] || return 1
  awk '{ print $22 }' "/proc/$pid/stat" 2>/dev/null
}

usage_common() {
  cat <<'EOF'
ocx-bash-cli — OpenCode eXtended CLI

Lệnh chính:
  ocx start [alias] [--mini] [--auto] [--dir DIR] [--dry-run]
      Mở phiên OpenCode mới với model đã cấu hình.
  ocx tui
      Mở OpenCode TUI bình thường.
  ocx run [-m alias] [--fallback] [--vpn-rotate] [--vpn-region R]
          [--vpn-rotate-max N] [--vpn-timeout S] [--run-timeout S] [--] <prompt...>
      Chạy một prompt. --fallback chỉ retry khi lỗi quota/model và chưa có tool call.
      --vpn-rotate: giữ nguyên model đã chọn; gặp free usage limit, timeout hoặc
      lỗi mạng thì xoay VPN và thử lại.
      --vpn-region R: xoay trong region R; mặc định giữ region hiện tại.
      --vpn-rotate-max N: số lần xoay tối đa (mặc định 20; 0 = không giới hạn).
      --vpn-timeout S: timeout mỗi lần kết nối/kiểm tra IP VPN (mặc định 30s).
      --run-timeout S: timeout mỗi lần gọi OpenCode (mặc định 180s; 0 = tắt).
  ocx models [--refresh]
      Liệt kê alias, model và trạng thái có trong `opencode models`.
  ocx model current|list|switch|next
      Xem/đổi model của phiên OpenCode đang chạy qua API.
  ocx fallback
      Alias của `ocx model next` (chuyển phiên active sang model kế tiếp).
  ocx vpn list|regions|import|use|next|random|region|auto|test|status|disconnect|log
      Quản lý profile VPN OpenVPN/WireGuard.
  ocx doctor
      Kiểm tra phụ thuộc, cấu hình, profile và API OpenCode.
  ocx version
      In phiên bản.

Ví dụ:
  ocx vpn import ~/Workspace/test/vpn_vn --region vn
  ocx vpn import ~/Workspace/test/japan --region jp
  ocx vpn list
  ocx vpn next
  ocx vpn region jp
  ocx vpn status
  ocx model next
  ocx run --fallback "Refactor hàm parseToken"
  ocx run --fallback --vpn-rotate --vpn-region jp "Refactor hàm parseToken"
  ocx run --vpn-rotate --vpn-rotate-max 50 --vpn-timeout 20 "Refactor hàm parseToken"

Lưu ý:
  - VPN không làm mới quota của tài khoản/model. Dùng model/provider hợp lệ khác.
  - ocx không tự replay prompt nếu model đã gọi tool (có thể đã sửa file).
EOF
}

usage_vpn() {
  cat <<'EOF'
Cách dùng ocx vpn:
  ocx vpn list [--region R] [--backend openvpn|wireguard]
  ocx vpn regions
  ocx vpn import <file|dir>... [--region R] [--name NAME] [--force]
  ocx vpn use <profile> [--failover] [--require-new-ip]
  ocx vpn next [--region R] [--same-region] [--random] [--no-failover]
  ocx vpn random [--region R]
  ocx vpn region <R>              (alias: use-region)
  ocx vpn auto [--region R]
  ocx vpn test <profile> [--keep]
  ocx vpn status
  ocx vpn disconnect [--all]
  ocx vpn log [lines]

Profile OpenVPN:   ~/.config/ocx/vpn/<region>/<name>.ovpn
Profile WireGuard: ~/.config/ocx/wireguard/<region>/<name>.conf
Tên profile có thể là <name> hoặc <region>/<name>.
EOF
}

usage_model() {
  cat <<'EOF'
Cách dùng ocx model:
  ocx model list
  ocx model current [--session ID]
  ocx model switch <alias|provider/model> [--session ID]
  ocx model next [--session ID]

Không có --session: ocx dùng biến OPENCODE_SESSION_ID, hoặc phiên active
duy nhất của OpenCode. Nếu có nhiều phiên, chỉ định --session.
EOF
}

version() { printf '%s %s\n' "$APP" "$VERSION"; }

doctor() {
  local failed=0
  printf 'ocx %s\n\n' "$VERSION"

  local cmd
  for cmd in "$OPENCODE_BIN" "$CURL_BIN" "$SUDO_BIN" "$JQ_BIN"; do
    if command -v "$cmd" >/dev/null 2>&1; then
      printf '[OK]      %-12s %s\n' "$cmd" "$(command -v "$cmd")"
    else
      printf '[MISSING] %-12s\n' "$cmd"; failed=1
    fi
  done

  if find "$OCX_VPN_DIR" -type f -name '*.ovpn' -print -quit 2>/dev/null | grep -q .; then
    if command -v "$OPENVPN_BIN" >/dev/null 2>&1; then
      printf '[OK]      %-12s %s\n' "$OPENVPN_BIN" "$(command -v "$OPENVPN_BIN")"
    else
      printf '[MISSING] %-12s (có profile .ovpn)\n' "$OPENVPN_BIN"; failed=1
    fi
  else
    printf '[SKIP]    %-12s chưa có profile .ovpn\n' "$OPENVPN_BIN"
  fi

  if find "$OCX_WG_DIR" -type f -name '*.conf' -print -quit 2>/dev/null | grep -q .; then
    for cmd in "$WG_QUICK_BIN" "$WG_BIN" "$IP_BIN"; do
      if command -v "$cmd" >/dev/null 2>&1; then
        printf '[OK]      %-12s %s\n' "$cmd" "$(command -v "$cmd")"
      else
        printf '[MISSING] %-12s (có profile WireGuard)\n' "$cmd"; failed=1
      fi
    done
  else
    printf '[SKIP]    %-12s chưa có profile WireGuard\n' "$WG_QUICK_BIN"
  fi

  if [[ -f "$OCX_MODELS_FILE" ]]; then
    printf '[OK]      models.conf  %s\n' "$OCX_MODELS_FILE"
  else
    printf '[MISSING] models.conf  %s\n' "$OCX_MODELS_FILE"; failed=1
  fi

  if [[ -d "$OCX_VPN_DIR" ]]; then
    local count
    count=$(find "$OCX_VPN_DIR" -type f -name '*.ovpn' 2>/dev/null | wc -l | tr -d ' ')
    printf '[OK]      vpn dir      %s (%s profile)\n' "$OCX_VPN_DIR" "$count"
  fi

  if command -v "$OPENCODE_BIN" >/dev/null 2>&1; then
    if "$OPENCODE_BIN" api get /api/info >/dev/null 2>&1; then
      printf '[OK]      OpenCode API phản hồi\n'
    else
      printf '[WARN]    OpenCode API chưa phản hồi; thử: opencode service restart\n'
    fi
  fi

  if [[ -s "$OCX_STATE_FILE" ]]; then
    state_load
    printf '[INFO]    VPN đang quản lý: %s %s\n' "$ACTIVE_BACKEND" "$ACTIVE_PROFILE"
  else
    printf '[INFO]    Không có VPN do ocx quản lý\n'
  fi

  if command -v "$CURL_BIN" >/dev/null 2>&1; then
    local ip
    ip=$(fetch_ip 2>/dev/null || true)
    [[ -n "$ip" ]] && printf '[INFO]    IPv4 public: %s\n' "$ip" \
                   || printf '[WARN]    Không lấy được IPv4 public\n'
  fi

  return "$failed"
}
