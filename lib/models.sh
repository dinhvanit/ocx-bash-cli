#!/usr/bin/env bash
# ocx — OpenCode model selection and safe fallback.

load_models() {
  [[ -f "$OCX_MODELS_FILE" ]] \
    || die "chưa có $OCX_MODELS_FILE. Chạy install.sh hoặc copy config/models.conf.example."

  # Source trong subshell để `declare -A` trong file cấu hình không tạo
  # biến local trong function này. Sau đó eval các khai báo với `-g`.
  local dump
  dump="$(
    # shellcheck disable=SC1090
    source "$OCX_MODELS_FILE"
    declare -p OCX_MODEL_PRIMARY 2>/dev/null || true
    declare -p OCX_MODEL_ALIASES 2>/dev/null || true
    declare -p OCX_MODEL_ORDER 2>/dev/null || true
    declare -p OCX_MODEL_FALLBACKS 2>/dev/null || true
  )"
  [[ -n "$dump" ]] || die "không đọc được cấu hình model: $OCX_MODELS_FILE"
  dump="$(printf '%s\n' "$dump" | sed \
    -e 's/^declare -A /declare -gA /' \
    -e 's/^declare -a /declare -ga /' \
    -e 's/^declare -- /declare -g /')"
  eval "$dump"

  declare -p OCX_MODEL_ALIASES >/dev/null 2>&1 || declare -gA OCX_MODEL_ALIASES=()
  declare -p OCX_MODEL_ORDER >/dev/null 2>&1 || OCX_MODEL_ORDER=()
  declare -p OCX_MODEL_FALLBACKS >/dev/null 2>&1 || OCX_MODEL_FALLBACKS=()

  [[ -n "${OCX_MODEL_PRIMARY:-}" ]] || die "OCX_MODEL_PRIMARY chưa được đặt trong $OCX_MODELS_FILE"

  if ((${#OCX_MODEL_ORDER[@]} == 0)); then
    OCX_MODEL_ORDER=(primary)
    local alias
    for alias in "${!OCX_MODEL_ALIASES[@]}"; do
      [[ "$alias" == "primary" ]] && continue
      OCX_MODEL_ORDER+=("$alias")
    done
  fi
}

parse_model_ref() {
  local ref="$1"
  [[ "$ref" == */* ]] || die "model phải có dạng provider/model: $ref"
  MODEL_PROVIDER="${ref%%/*}"
  MODEL_ID="${ref#*/}"
  MODEL_VARIANT=""
  if [[ "$MODEL_ID" == *#* ]]; then
    MODEL_VARIANT="${MODEL_ID#*#}"
    MODEL_ID="${MODEL_ID%%#*}"
  fi
  [[ -n "$MODEL_PROVIDER" && -n "$MODEL_ID" ]] || die "model không hợp lệ: $ref"
}

strip_model_variant() { printf '%s' "${1%%#*}"; }

model_resolve() {
  local alias="${1:-}" model=""
  if [[ -z "$alias" ]]; then
    printf '%s' "$OCX_MODEL_PRIMARY"
    return 0
  fi
  if [[ "$alias" == "primary" ]]; then
    model="$OCX_MODEL_PRIMARY"
  elif [[ -n "${OCX_MODEL_ALIASES[$alias]:-}" ]]; then
    model="${OCX_MODEL_ALIASES[$alias]}"
  elif [[ "$alias" == */* ]]; then
    model="$alias"
  else
    die "không biết alias model '$alias'. Xem: ocx models"
  fi
  [[ -n "$model" ]] || die "alias '$alias' chưa được cấu hình"
  printf '%s' "$model"
}

model_alias_of() {
  local model="${1%%#*}" alias amodel
  if [[ "$model" == "${OCX_MODEL_PRIMARY%%#*}" ]]; then
    printf 'primary'; return 0
  fi
  for alias in "${OCX_MODEL_ORDER[@]}"; do
    [[ "$alias" == "primary" ]] && continue
    amodel="${OCX_MODEL_ALIASES[$alias]:-}"
    if [[ "$amodel" == "$model" || "${amodel%%#*}" == "$model" ]]; then
      printf '%s' "$alias"; return 0
    fi
  done
  return 1
}

model_chain() {
  local alias model
  local -A seen=()
  for alias in "${OCX_MODEL_ORDER[@]}"; do
    model="$(model_resolve "$alias" 2>/dev/null || true)"
    [[ -n "$model" ]] || continue
    [[ -n "${seen[$model]:-}" ]] && continue
    seen["$model"]=1
    printf '%s\n' "$model"
  done
}

# ---------------------------------------------------------------------------
# Model catalog cache
# ---------------------------------------------------------------------------
models_cache_refresh() {
  local force="${1:-0}" mtime now age
  if truthy "$force"; then :; else
    if [[ -s "$OCX_MODELS_CACHE" ]]; then
      mtime="$(stat -c %Y "$OCX_MODELS_CACHE" 2>/dev/null || printf 0)"
      now="$(now_epoch)"
      age=$((now - mtime))
      (( age < OCX_MODELS_CACHE_TTL )) && return 0
    fi
  fi
  require_cmd "$OPENCODE_BIN"
  local tmp="$OCX_MODELS_CACHE.tmp.$$"
  if "$OPENCODE_BIN" models > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$OCX_MODELS_CACHE"
    return 0
  fi
  rm -f "$tmp"
  warn "không lấy được danh sách model từ '$OPENCODE_BIN models'"
  return 1
}

# 0 = available, 1 = not found, 2 = unknown (no cache)
model_available() {
  local model="${1%%#*}"
  [[ -s "$OCX_MODELS_CACHE" ]] || return 2
  if grep -Fxq "$model" "$OCX_MODELS_CACHE"; then return 0; fi
  return 1
}

models_cmd() {
  local refresh=0
  while (($#)); do
    case "$1" in
      --refresh) refresh=1; shift ;;
      -h|--help) usage_common; return 0 ;;
      *) die "tham số không hợp lệ cho models: $1" ;;
    esac
  done
  load_models
  models_cache_refresh "$refresh" >/dev/null 2>&1 || true

  printf '%-3s %-14s %-48s %s\n' "#" "ALIAS" "MODEL" "CÓ SẴN"
  local i=0 alias model avail mark
  for alias in "${OCX_MODEL_ORDER[@]}"; do
    model="$(model_resolve "$alias" 2>/dev/null || true)"
    [[ -n "$model" ]] || continue
    i=$((i + 1))
    avail=0
    model_available "$model" || avail=$?
    case "$avail" in
      0) mark="yes" ;;
      1) mark="KHÔNG" ;;
      *) mark="?" ;;
    esac
    printf '%-3s %-14s %-48s %s\n' "$i" "$alias" "$model" "$mark"
  done
  printf '\nFallback order: '
  model_chain | awk 'NR == 1 { printf "%s", $0; next } { printf " -> %s", $0 } END { print "" }'
  if [[ ! -s "$OCX_MODELS_CACHE" ]]; then
    printf 'Chưa có cache model. Chạy: ocx models --refresh\n'
  fi
}

# ---------------------------------------------------------------------------
# OpenCode API
# ---------------------------------------------------------------------------
api_call() {
  require_cmd "$OPENCODE_BIN"
  local out
  if ! out="$("$OPENCODE_BIN" api "$@" 2>&1)"; then
    printf '%s\n' "$out" >&2
    return 1
  fi
  printf '%s' "$out"
}

session_active_ids() {
  local out
  out="$(api_call get /api/session/active)" || return 1
  "$JQ_BIN" -r '.data | keys[]' <<< "$out" 2>/dev/null || true
}

session_resolve() {
  local sid="${1:-}"
  if [[ -n "$sid" ]]; then printf '%s' "$sid"; return 0; fi
  if [[ -n "${OPENCODE_SESSION_ID:-}" ]]; then printf '%s' "$OPENCODE_SESSION_ID"; return 0; fi

  local -a ids=()
  mapfile -t ids < <(session_active_ids 2>/dev/null || true)
  if ((${#ids[@]} == 0)); then
    die "không tìm thấy phiên OpenCode đang active. Mở OpenCode trước hoặc dùng --session ID."
  fi
  if ((${#ids[@]} > 1)); then
    printf 'ocx: có nhiều phiên đang active, hãy chỉ định --session:\n' >&2
    printf '  %s\n' "${ids[@]}" >&2
    return 2
  fi
  printf '%s' "${ids[0]}"
}

session_create() {
  local model="$1" title="${2:-ocx}" dir="${3:-$PWD}"
  require_cmd "$JQ_BIN"
  parse_model_ref "$model"
  local json out sid
  json="$("$JQ_BIN" -n \
    --arg provider "$MODEL_PROVIDER" \
    --arg id "$MODEL_ID" \
    --arg variant "$MODEL_VARIANT" \
    --arg title "$title" \
    --arg dir "$dir" \
    '{title: $title, model: ({providerID: $provider, id: $id} + (if $variant != "" then {variant: $variant} else {} end)), location: {directory: $dir}}')"
  out="$(api_call post /api/session -d "$json")" || return 1
  sid="$("$JQ_BIN" -r '.data.id // empty' <<< "$out" 2>/dev/null || true)"
  [[ -n "$sid" ]] || { warn "OpenCode không trả về session ID"; return 1; }
  printf '%s' "$sid"
}

session_switch_model() {
  local sid="$1" model="$2"
  require_cmd "$JQ_BIN"
  parse_model_ref "$model"
  local json
  json="$("$JQ_BIN" -n \
    --arg provider "$MODEL_PROVIDER" \
    --arg id "$MODEL_ID" \
    --arg variant "$MODEL_VARIANT" \
    '{model: ({providerID: $provider, id: $id} + (if $variant != "" then {variant: $variant} else {} end))}')"
  api_call post "/api/session/$sid/model" -d "$json" >/dev/null
}

session_model_ref() {
  local sid="$1" out
  out="$(api_call get "/api/session/$sid")" || return 1
  "$JQ_BIN" -r '
    .data.model as $m
    | if $m == null then "" else
        ($m.providerID + "/" + $m.id
         + (if ($m.variant // "default") != "default" then "#" + $m.variant else "" end))
      end' <<< "$out" 2>/dev/null || true
}

model_current() {
  local session=""
  while (($#)); do
    case "$1" in
      --session) session="${2:-}"; shift 2 ;;
      -h|--help) usage_model; return 0 ;;
      *) die "tham số không hợp lệ cho model current: $1" ;;
    esac
  done
  load_models
  local sid ref alias
  sid="$(session_resolve "$session")" || return $?
  ref="$(session_model_ref "$sid")" || return 1
  printf 'Session: %s\n' "$sid"
  if [[ -z "$ref" ]]; then
    printf 'Model:   (chưa chọn)\n'
    return 0
  fi
  printf 'Model:   %s\n' "$ref"
  if alias="$(model_alias_of "$ref")"; then
    printf 'Alias:   %s\n' "$alias"
  fi
}

model_switch() {
  local alias="" session=""
  while (($#)); do
    case "$1" in
      --session) session="${2:-}"; shift 2 ;;
      -h|--help) usage_model; return 0 ;;
      *) alias="$1"; shift ;;
    esac
  done
  [[ -n "$alias" ]] || die "cách dùng: ocx model switch <alias|provider/model> [--session ID]"
  load_models
  local model sid
  model="$(model_resolve "$alias")"
  parse_model_ref "$model"
  sid="$(session_resolve "$session")" || return $?
  session_switch_model "$sid" "$model" || die "không chuyển được model của session $sid"
  ok "đã chuyển session $sid sang $model"
}

model_next() {
  local session=""
  while (($#)); do
    case "$1" in
      --session) session="${2:-}"; shift 2 ;;
      -h|--help) usage_model; return 0 ;;
      *) die "tham số không hợp lệ cho model next: $1" ;;
    esac
  done
  load_models
  models_cache_refresh 0 >/dev/null 2>&1 || true
  local sid current current_base
  sid="$(session_resolve "$session")" || return $?
  current="$(session_model_ref "$sid")" || return 1
  [[ -n "$current" ]] || current="$(model_resolve primary)"
  current_base="${current%%#*}"

  local -a chain=()
  mapfile -t chain < <(model_chain)
  ((${#chain[@]} > 0)) || die "fallback chain rỗng; kiểm tra $OCX_MODELS_FILE"

  local i idx=-1 next="" candidate av
  for ((i = 0; i < ${#chain[@]}; i++)); do
    if [[ "${chain[$i]}" == "$current" || "${chain[$i]}" == "$current_base" ]]; then
      idx=$i; break
    fi
  done

  # Bỏ qua model đã biết là không có trong catalog; nếu cache chưa có
  # (model_available trả 2) thì vẫn chọn theo thứ tự.
  for ((i = 1; i <= ${#chain[@]}; i++)); do
    candidate="${chain[$(( (idx + i + ${#chain[@]}) % ${#chain[@]} ))]}"
    av=0
    model_available "$candidate" || av=$?
    if (( av != 1 )); then next="$candidate"; break; fi
  done
  [[ -n "$next" ]] || next="${chain[$(( (idx + 1 + ${#chain[@]}) % ${#chain[@]} ))]}"

  session_switch_model "$sid" "$next" || die "không chuyển được session $sid sang $next"
  ok "session $sid: $current -> $next"
}

next_model_after() {
  local model="${1%%#*}" i
  local -a chain=()
  mapfile -t chain < <(model_chain)
  ((${#chain[@]} > 0)) || { printf '%s' "$model"; return 0; }
  for ((i = 0; i < ${#chain[@]}; i++)); do
    if [[ "${chain[$i]}" == "$model" ]]; then
      printf '%s' "${chain[$(( (i + 1) % ${#chain[@]} ))]}"
      return 0
    fi
  done
  printf '%s' "${chain[0]}"
}

# ---------------------------------------------------------------------------
# Start / run
# ---------------------------------------------------------------------------
model_start() {
  local alias="primary" mini=0 auto=0 dry=0 force=0 dir="$PWD"
  while (($#)); do
    case "$1" in
      --mini) mini=1; shift ;;
      --auto) auto=1; shift ;;
      --dry-run) dry=1; shift ;;
      --force) force=1; shift ;;
      --dir) dir="${2:-}"; shift 2 ;;
      -h|--help) usage_common; return 0 ;;
      *) alias="$1"; shift ;;
    esac
  done
  load_models
  require_cmd "$OPENCODE_BIN"
  models_cache_refresh 0 >/dev/null 2>&1 || true

  local model
  if truthy "$auto"; then
    model=""
    local m
    while IFS= read -r m; do
      if model_available "$m"; then model="$m"; break; fi
    done < <(model_chain)
    [[ -n "$model" ]] || model="$(model_resolve primary)"
  else
    model="$(model_resolve "$alias")"
  fi
  parse_model_ref "$model"

  if ! truthy "$force"; then
    local av=0
    model_available "$model" || av=$?
    if (( av == 1 )); then
      die "model '$model' không có trong 'opencode models'. Kiểm tra lại hoặc dùng --force."
    fi
  fi

  [[ -d "$dir" ]] || die "thư mục không tồn tại: $dir"
  dir="$(cd "$dir" && pwd)"

  local sid=""
  if ! sid="$(session_create "$model" "ocx: $alias" "$dir" 2>/dev/null)"; then
    warn "không tạo được session qua API OpenCode; mở TUI mặc định"
    if truthy "$dry"; then
      printf 'model: %s\ncommand: %s %q\n' "$model" "$OPENCODE_BIN" "$dir"
      return 1
    fi
    if truthy "$mini"; then
      (cd "$dir" && exec "$OPENCODE_BIN" mini)
    else
      exec "$OPENCODE_BIN" "$dir"
    fi
  fi

  if truthy "$dry"; then
    printf 'session: %s\nmodel: %s\n' "$sid" "$model"
    if truthy "$mini"; then
      printf 'command: %s mini --session %s --model %s\n' "$OPENCODE_BIN" "$sid" "$model"
    else
      printf 'command: %s --session %s %q\n' "$OPENCODE_BIN" "$sid" "$dir"
    fi
    if ! truthy "${OCX_KEEP_DRY_SESSION:-0}"; then
      api_call delete "/api/session/$sid" >/dev/null 2>&1 || true
      printf '(session tạm đã xoá; đặt OCX_KEEP_DRY_SESSION=1 để giữ)\n'
    fi
    return 0
  fi

  info "mở OpenCode: session=$sid model=$model"
  if truthy "$mini"; then
    exec "$OPENCODE_BIN" mini --session "$sid" --model "$model"
  else
    exec "$OPENCODE_BIN" --session "$sid" "$dir"
  fi
}

classify_error() {
  local text
  text="$(lower "$1")"
  case "$text" in
    *context\ length*|*context\ window*|*maximum\ context*|*too\ many\ tokens*|*token\ limit*)
      printf 'context'; return ;;
    *free\ usage\ limit*|*free\ models\ work\ in\ opencode*|*subscribe\ to\ opencode\ go*)
      printf 'free_limit'; return ;;
    *quota*|*usage\ limit*|*usage_limit*|*exhausted*|*insufficient_quota*|*billing*|*credit*|*daily\ limit*|*monthly\ limit*)
      printf 'quota'; return ;;
    *rate\ limit*|*rate_limit*|*429*|*too\ many\ requests*|*temporarily\ limited*)
      printf 'rate'; return ;;
    *model\ unavailable*|*no-route*|*no_route*|*not\ found*|*does\ not\ exist*|*unavailable*)
      printf 'unavailable'; return ;;
    *unauthorized*|*forbidden*|*invalid\ api\ key*|*credential*|*auth*|*401*|*403*)
      printf 'auth'; return ;;
    *network*|*timeout*|*timed\ out*|*connection*|*dns*|*tls*|*certificate*|*econn*)
      printf 'network'; return ;;
    *) printf 'other' ;;
  esac
}

render_event() {
  local line="$1" type
  type="$("$JQ_BIN" -r '.type // empty' <<< "$line" 2>/dev/null || true)"
  case "$type" in
    text)
      "$JQ_BIN" -r '.part.text // empty' <<< "$line" 2>/dev/null || true
      ;;
    tool_use)
      printf '\n[ocx] tool: %s\n' \
        "$("$JQ_BIN" -r '.part.tool // "tool"' <<< "$line" 2>/dev/null || printf tool)"
      ;;
    error)
      printf '\n[ocx] error: %s\n' \
        "$("$JQ_BIN" -r '.error.message // .error.type // "unknown"' <<< "$line" 2>/dev/null || printf unknown)" >&2
      ;;
  esac
}

suggest_after_failure() {
  local model="$1" tools="$2" sid="$3" kind="$4" next
  next="$(next_model_after "$model")"
  printf '\n[ocx] model %s thất bại (%s).\n' "$model" "$kind" >&2
  if (( tools > 0 )); then
    printf '[ocx] Đã có %d tool call trước lỗi; KHÔNG tự retry để tránh lặp thao tác.\n' "$tools" >&2
    printf '[ocx] Kiểm tra thay đổi (git diff/status), rồi chuyển model cho cùng session:\n' >&2
  else
    printf '[ocx] Chưa có tool call; có thể chuyển model an toàn.\n' >&2
  fi
  printf '      ocx model switch %s%s\n' "$next" "${sid:+ --session $sid}" >&2
  [[ -n "$sid" ]] && printf '      opencode --session %s\n' "$sid" >&2
}

# Kết nối một profile VPN cụ thể để xoay IP. Không dùng failover nội bộ:
# vòng lặp trong model_run sẽ tự chọn profile kế tiếp nếu profile này lỗi.
rotate_vpn_to_profile() {
  local profile="$1" timeout="${2:-$OCX_RUN_VPN_TIMEOUT}"
  [[ -n "$profile" ]] || { warn "không có profile VPN để xoay"; return 1; }
  info "thử VPN: $profile"
  OCX_CONNECT_TIMEOUT="$timeout" OCX_IP_TIMEOUT="$timeout" \
    with_lock vpn_use "$profile" --no-failover --require-new-ip
}

model_run() {
  local alias="primary" fallback=0 vpn_region_flag=0
  local vpn_on_free_limit="${OCX_RUN_VPN_ON_FREE_LIMIT:-0}"
  local vpn_region="${OCX_RUN_VPN_REGION:-}"
  local vpn_max="${OCX_RUN_VPN_MAX:-20}"
  local vpn_timeout="${OCX_RUN_VPN_TIMEOUT:-30}"
  local run_timeout="${OCX_RUN_TIMEOUT:-180}"
  local -a prompt_parts=()
  while (($#)); do
    case "$1" in
      -m|--model) alias="${2:-}"; shift 2 ;;
      --fallback) fallback=1; shift ;;
      --vpn-rotate|--vpn-on-free-limit) vpn_on_free_limit=1; shift ;;
      --vpn-rotate-max|--vpn-max)
        [[ "${2:-}" =~ ^[0-9]+$ ]] || die "--vpn-rotate-max cần số nguyên >= 0"
        vpn_max="$2"; shift 2 ;;
      --vpn-timeout)
        [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || die "--vpn-timeout cần số nguyên dương (giây)"
        vpn_timeout="$2"; shift 2 ;;
      --run-timeout)
        [[ "${2:-}" =~ ^[0-9]+$ ]] || die "--run-timeout cần số nguyên >= 0 (giây)"
        run_timeout="$2"; shift 2 ;;
      --vpn-region)
        [[ -n "${2:-}" ]] || die "--vpn-region cần tên region"
        vpn_region="$(normalize_region "$2")"; vpn_region_flag=1; shift 2 ;;
      --) shift; prompt_parts+=("$@"); break ;;
      -h|--help) usage_common; return 0 ;;
      *) prompt_parts+=("$1"); shift ;;
    esac
  done
  ((${#prompt_parts[@]} > 0)) || die "cách dùng: ocx run [-m alias] [--fallback] [--vpn-rotate] [--vpn-region R] [--vpn-rotate-max N] [--vpn-timeout S] [--run-timeout S] <prompt...>"
  if (( vpn_region_flag == 1 )) && ! truthy "$vpn_on_free_limit"; then
    die "--vpn-region chỉ dùng cùng --vpn-rotate (hoặc OCX_RUN_VPN_ON_FREE_LIMIT=1)"
  fi
  [[ "$vpn_max" =~ ^[0-9]+$ ]] || die "OCX_RUN_VPN_MAX phải là số nguyên >= 0"
  [[ "$vpn_timeout" =~ ^[1-9][0-9]*$ ]] || die "OCX_RUN_VPN_TIMEOUT phải là số nguyên dương"
  [[ "$run_timeout" =~ ^[0-9]+$ ]] || die "OCX_RUN_TIMEOUT phải là số nguyên >= 0"
  load_models
  local prompt="${prompt_parts[*]}"
  local model
  model="$(model_resolve "$alias")"
  require_cmd "$OPENCODE_BIN"

  # --vpn-rotate cần chạy ở chế độ có retry/kiểm soát, kể cả khi người dùng
  # không truyền --fallback. Không dùng exec trực tiếp trong trường hợp này.
  if ! truthy "$fallback" && ! truthy "$vpn_on_free_limit"; then
    if (( run_timeout > 0 )) && have_cmd timeout; then
      exec timeout --signal=TERM --kill-after=5 "$run_timeout" \
        "$OPENCODE_BIN" run --model "$model" "$prompt"
    fi
    exec "$OPENCODE_BIN" run --model "$model" "$prompt"
  fi

  require_cmd "$JQ_BIN"
  models_cache_refresh 0 >/dev/null 2>&1 || true

  local -a chain=() candidates=()
  mapfile -t chain < <(model_chain)
  local found=0 m
  for m in "${chain[@]}"; do
    if [[ "$m" == "$model" ]]; then found=1; continue; fi
    (( found == 1 )) && candidates+=("$m")
  done
  if (( found == 1 )); then
    candidates=("$model" "${candidates[@]}")
  else
    # Model người dùng chọn không nằm trong fallback chain: vẫn thử nó
    # trước, sau đó thử toàn bộ chain.
    candidates=("$model" "${chain[@]}")
  fi
  # Chế độ xoay VPN giữ cố định model đã chọn; không fallback sang model khác.
  if truthy "$vpn_on_free_limit"; then
    candidates=("$model")
  fi

  local tmp rcfile rc error_json error_type error_msg kind tools sid
  tmp="$OCX_CACHE_DIR/run.$$.jsonl"
  rcfile="$OCX_CACHE_DIR/run.$$.rc"
  : > "$tmp"; : > "$rcfile"

  local success=0 idx=0 total=${#candidates[@]}
  local attempt can_retry

  # Chuẩn bị danh sách profile cho chế độ xoay VPN. Danh sách được chốt một
  # lần để vòng lặp vẫn tiếp tục đúng profile kế tiếp khi connect thất bại.
  local -a vpn_names=()
  local vpn_index=0 vpn_attempts=0 vpn_explicit_region=0
  local vpn_region_label="" vpn_current="" vi
  if truthy "$vpn_on_free_limit"; then
    [[ -n "$vpn_region" ]] && vpn_explicit_region=1
    if [[ -z "$vpn_region" ]]; then
      vpn_region="$(active_region 2>/dev/null || true)"
    fi
    if [[ -n "$vpn_region" ]]; then
      mapfile -t vpn_names < <(profile_names "$vpn_region")
      if (( vpn_explicit_region == 1 )); then
        vpn_region_label="region $vpn_region"
      else
        vpn_region_label="region hiện tại: $vpn_region"
      fi
    else
      mapfile -t vpn_names < <(profile_names "")
      vpn_region_label="mọi region"
    fi
    state_load
    vpn_current="${ACTIVE_PROFILE:-}"
    if [[ -n "$vpn_current" && ${#vpn_names[@]} -gt 0 ]]; then
      for ((vi = 0; vi < ${#vpn_names[@]}; vi++)); do
        if [[ "${vpn_names[$vi]}" == "$vpn_current" ]]; then
          vpn_index=$(( (vi + 1) % ${#vpn_names[@]} ))
          break
        fi
      done
    fi
    if (( ${#vpn_names[@]} == 0 )); then
      warn "không có profile VPN để xoay ($vpn_region_label)"
    fi
  fi

  for m in "${candidates[@]}"; do
    idx=$((idx + 1))
    attempt=0

    # Vòng lặp này chỉ tiếp tục khi xoay VPN thành công. Model được giữ cố
    # định trong chế độ --vpn-rotate.
    while :; do
      attempt=$((attempt + 1))
      if (( attempt == 1 )); then
        printf '\n[ocx] model %s (%d/%d)\n' "$m" "$idx" "$total"
      else
        printf '\n[ocx] model %s (%d/%d) - thử lại sau khi xoay VPN\n' "$m" "$idx" "$total"
      fi
      : > "$tmp"; : > "$rcfile"

      set +e
      if (( run_timeout > 0 )) && have_cmd timeout; then
        ( timeout --signal=TERM --kill-after=5 "$run_timeout" \
            "$OPENCODE_BIN" run --format json --model "$m" "$prompt"; printf '%s' "$?" > "$rcfile" ) \
          | while IFS= read -r line; do
              printf '%s\n' "$line" >> "$tmp"
              render_event "$line"
            done
      else
        ( "$OPENCODE_BIN" run --format json --model "$m" "$prompt"; printf '%s' "$?" > "$rcfile" ) \
          | while IFS= read -r line; do
              printf '%s\n' "$line" >> "$tmp"
              render_event "$line"
            done
      fi
      set -e

      rc="$(cat "$rcfile" 2>/dev/null || printf 1)"
      printf '\n'
      if [[ "$rc" == "0" ]]; then
        # Model trả lời được với VPN hiện tại: xoá mark limit/fail của profile
        # này để lần sau không bỏ qua một IP vẫn còn dùng được.
        state_load
        if [[ -n "${ACTIVE_PROFILE:-}" ]]; then
          vpn_mark_clear "$ACTIVE_PROFILE" "limit" || true
          vpn_mark_clear "$ACTIVE_PROFILE" "fail" || true
        fi
        success=1
        break 2
      fi

      error_json="$("$JQ_BIN" -c 'select(.type == "error") | .error' "$tmp" 2>/dev/null | tail -n 1 || true)"
      error_type=""
      error_msg=""
      if [[ -n "$error_json" ]]; then
        error_type="$("$JQ_BIN" -r '.type // ""' <<< "$error_json" 2>/dev/null || true)"
        error_msg="$("$JQ_BIN" -r '.message // ""' <<< "$error_json" 2>/dev/null || true)"
      fi
      tools="$("$JQ_BIN" -r 'select(.type == "tool_use") | .part.tool // "tool"' "$tmp" 2>/dev/null | wc -l | tr -d ' ')"
      sid="$("$JQ_BIN" -r 'select(.sessionID != null) | .sessionID' "$tmp" 2>/dev/null | head -n 1 || true)"
      kind="$(classify_error "$error_type $error_msg")"
      # Một số phiên bản OpenCode có thể chỉ in lỗi dạng text trong JSONL.
      if [[ "$kind" == "other" ]] \
         && grep -qiE 'free usage limit reached|free models work in opencode|subscribe to opencode go' "$tmp"; then
        kind="free_limit"
      fi
      # `timeout` trả 124 khi tiến trình không phản hồi.
      if [[ "$rc" == "124" ]]; then
        kind="timeout"
      fi

      # Đánh dấu profile đang dùng là hết quota để các lần xoay sau bỏ qua.
      # Chỉ mark khi có VPN do ocx quản lý; không mark nếu model chạy trực tiếp.
      if [[ "$kind" == "free_limit" ]]; then
        state_load
        if [[ -n "${ACTIVE_PROFILE:-}" ]]; then
          vpn_mark_record "$ACTIVE_PROFILE" "limit" "free usage limit" || true
          info "đánh dấu limit: $ACTIVE_PROFILE"
        fi
      fi

      # Xoay VPN khi free limit, timeout hoặc lỗi mạng, nhưng tuyệt đối không
      # khi đã có tool call. Mỗi lần xoay thử một profile; profile lỗi thì
      # chuyển ngay sang profile kế tiếp.
      if truthy "$vpn_on_free_limit" && (( tools == 0 )) \
         && [[ "$kind" == "free_limit" || "$kind" == "timeout" || "$kind" == "network" ]]; then
        case "$kind" in
          free_limit) warn "gặp free usage limit trước khi có tool call" ;;
          timeout)    warn "model không phản hồi (timeout) trước khi có tool call" ;;
          network)    warn "gặp lỗi mạng trước khi có tool call" ;;
        esac
        if (( ${#vpn_names[@]} == 0 )); then
          warn "không có profile VPN để xoay; dừng"
          break
        fi
        if (( vpn_max > 0 && vpn_attempts >= vpn_max )); then
          warn "đã đạt giới hạn $vpn_max lần xoay VPN; dừng"
          break
        fi
        if truthy "$OCX_CHECK_UNMANAGED_VPN"; then
          local -a unmanaged=()
          mapfile -t unmanaged < <(unmanaged_openvpn_pids)
          if (( ${#unmanaged[@]} > 0 )); then
            warn "phát hiện OpenVPN không do ocx quản lý: PID ${unmanaged[*]}"
            warn "hãy dừng VPN đó trước rồi thử lại; ocx không tự kill process ngoài state/pidfile"
            break
          fi
        fi

        local rotated=0 target scanned=0
        local before_attempts="$vpn_attempts"
        while (( scanned < ${#vpn_names[@]} )) \
          && (( vpn_max == 0 || vpn_attempts < vpn_max )); do
          target="${vpn_names[$vpn_index]}"
          vpn_index=$(( (vpn_index + 1) % ${#vpn_names[@]} ))
          scanned=$((scanned + 1))

          # Bỏ qua profile đã được đánh dấu limit (trong ngày UTC) hoặc fail
          # (trong OCX_VPN_FAIL_TTL), để xoay sang IP chưa thử.
          if vpn_mark_blocked "$target"; then
            info "bỏ qua $target ($(vpn_mark_label "$target"))"
            continue
          fi

          vpn_attempts=$((vpn_attempts + 1))
          if (( vpn_max > 0 )); then
            info "xoay VPN trong $vpn_region_label (${vpn_attempts}/${vpn_max})"
          else
            info "xoay VPN trong $vpn_region_label (${vpn_attempts})"
          fi
          if rotate_vpn_to_profile "$target" "$vpn_timeout"; then
            rotated=1
            break
          fi
          warn "VPN $target không kết nối được; thử profile tiếp theo"
        done
        if (( rotated == 1 )); then
          info "đã xoay VPN; thử lại model $m"
          continue
        fi
        if (( vpn_attempts == before_attempts )); then
          warn "không còn profile chưa đánh dấu trong $vpn_region_label"
          warn "mark limit tự hết hạn sau 0h UTC; reset sớm: ocx vpn reset --limit"
          warn "nếu profile bị fail: ocx vpn reset --fail"
        else
          warn "không xoay được VPN sau $((vpn_attempts - before_attempts)) lần thử; dừng"
        fi
        break
      fi
      break
    done

    can_retry=0
    case "$kind" in
      quota|unavailable|free_limit) (( tools == 0 )) && can_retry=1 ;;
      rate) truthy "$OCX_RUN_FALLBACK_ON_RATE_LIMIT" && (( tools == 0 )) && can_retry=1 ;;
    esac

    if (( can_retry == 1 && idx < total )); then
      warn "lỗi $kind trước khi có tool call; thử model tiếp theo"
      continue
    fi

    if truthy "$vpn_on_free_limit" && (( tools == 0 )); then
      printf '\n[ocx] model %s vẫn lỗi (%s) ở chế độ giữ model cố định.\n' "$m" "$kind" >&2
    else
      suggest_after_failure "$m" "$tools" "$sid" "$kind"
    fi
    if [[ "$kind" == "rate" ]]; then
      printf '[ocx] 429 có thể chỉ là giới hạn tạm thời. Thử lại sau hoặc đặt OCX_RUN_FALLBACK_ON_RATE_LIMIT=1.\n' >&2
    elif [[ "$kind" == "free_limit" ]]; then
      if truthy "$vpn_on_free_limit"; then
        printf '[ocx] Free usage limit vẫn còn sau khi thử xoay VPN. Kiểm tra IP/region hoặc thử VPN khác.\n' >&2
      else
        printf '[ocx] Free usage limit: dùng --vpn-rotate (hoặc OCX_RUN_VPN_ON_FREE_LIMIT=1) để xoay VPN.\n' >&2
      fi
    elif [[ "$kind" == "auth" ]]; then
      printf '[ocx] Lỗi xác thực: chạy opencode auth list / /connect để kiểm tra provider.\n' >&2
    elif [[ "$kind" == "network" ]]; then
      printf '[ocx] Lỗi mạng: kiểm tra VPN/kết nối trước khi đổi model.\n' >&2
    elif [[ "$kind" == "timeout" ]]; then
      printf '[ocx] Timeout: model không phản hồi trong %ss. Kiểm tra VPN hoặc tăng --run-timeout.\n' "$run_timeout" >&2
    elif [[ "$kind" == "context" ]]; then
      printf '[ocx] Hết context: dùng /compact hoặc model có context lớn hơn.\n' >&2
    fi
    break
  done

  rm -f "$tmp" "$rcfile"
  truthy "$success" || return 1
}

model_help() { usage_model; }
