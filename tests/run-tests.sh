#!/usr/bin/env bash
# Test ocx without touching the real network, VPN, or OpenCode quota.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OCX="$ROOT/bin/ocx"
TMP="$(mktemp -d)"
trap 'cleanup' EXIT

PASS=0
FAIL=0

cleanup() {
  if [[ -n "${MOCK_PIDS_FILE:-}" && -f "$MOCK_PIDS_FILE" ]]; then
    while read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] && kill -TERM "$pid" 2>/dev/null || true
    done < "$MOCK_PIDS_FILE"
  fi
  rm -rf "$TMP"
}

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then ok "$name"; else
    bad "$name"; printf '      expected to contain: %s\n' "$needle" >&2
    printf '      got: %s\n' "$haystack" >&2
  fi
}
assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" != *"$needle"* ]]; then ok "$name"; else
    bad "$name"; printf '      did not expect: %s\n' "$needle" >&2
  fi
}
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then ok "$name"; else
    bad "$name"; printf '      got: %s\n      want: %s\n' "$got" "$want" >&2
  fi
}

run_capture() {
  set +e
  OUTPUT="$("$@" 2>&1)"
  RC=$?
  set -e
}

write_config() {
  cp "$ROOT/config/models.conf.example" "$OCX_CONFIG_DIR/models.conf"
  cat > "$OCX_CONFIG_DIR/ocx.conf" <<EOF
OCX_CONNECT_TIMEOUT=3
OCX_IP_TIMEOUT=3
OCX_SUDO=ask
OCX_SUDO_NONINTERACTIVE=1
OCX_FAILOVER=1
OCX_REQUIRE_IP_CHANGE=0
OCX_RUN_FALLBACK_ON_RATE_LIMIT=0
OCX_RUN_VPN_MAX=20
OCX_RUN_VPN_TIMEOUT=3
OCX_RUN_TIMEOUT=10
OCX_CHECK_UNMANAGED_VPN=0
EOF
}

new_env() {
  local name="$1"
  ENV_DIR="$TMP/$name"
  unset OPENCODE_SESSION_ID || true
  export OCX_CONFIG_DIR="$ENV_DIR/config"
  export OCX_CACHE_DIR="$ENV_DIR/cache"
  export OCX_STATE_DIR="$ENV_DIR/state"
  export OCX_STATE_FILE="$ENV_DIR/state/vpn.state"
  export OCX_TEST_IP_FILE="$ENV_DIR/ip.txt"
  export OCX_TEST_WG_FILE="$ENV_DIR/wg.up"
  export MOCK_PIDS_FILE="$ENV_DIR/mock.pids"
  export MOCK_MODEL_FILE="$ENV_DIR/model.txt"
  export MOCK_FREE_LIMIT_FILE="$ENV_DIR/free-limit.count"
  export MOCK_TIMEOUT_FILE="$ENV_DIR/timeout.count"
  export MOCK_RUN_MODE="${MOCK_RUN_MODE:-normal}"
  mkdir -p "$OCX_CONFIG_DIR/vpn/vn" "$OCX_CONFIG_DIR/vpn/jp" \
           "$OCX_CONFIG_DIR/wireguard/us" "$OCX_CACHE_DIR" "$OCX_STATE_DIR"
  printf '203.0.113.10' > "$OCX_TEST_IP_FILE"
  rm -f "$OCX_TEST_IP_FILE.counter" "$MOCK_FREE_LIMIT_FILE" "$MOCK_TIMEOUT_FILE"
  printf 'opencode/deepseek-v4.1-flash-free' > "$MOCK_MODEL_FILE"
  : > "$MOCK_PIDS_FILE"
  write_config
}

# ---------------------------------------------------------------------------
# Mocks
# ---------------------------------------------------------------------------
make_mocks() {
  MOCK_BIN="$TMP/bin"
  mkdir -p "$MOCK_BIN"

  cat > "$MOCK_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

  cat > "$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
cat "$OCX_TEST_IP_FILE"
EOF

  cat > "$MOCK_BIN/ip" <<'EOF'
#!/usr/bin/env bash
[[ -f "$OCX_TEST_WG_FILE" ]]
EOF

  cat > "$MOCK_BIN/wg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$MOCK_BIN/wg-quick" <<'EOF'
#!/usr/bin/env bash
set -e
action="$1"; path="$2"
case "$action" in
  up)
    printf '198.51.100.77' > "$OCX_TEST_IP_FILE"
    : > "$OCX_TEST_WG_FILE"
    ;;
  down)
    rm -f "$OCX_TEST_WG_FILE"
    ;;
esac
EOF

  cat > "$MOCK_BIN/openvpn" <<'EOF'
#!/usr/bin/env bash
set -e
pidfile=""; logfile=""; config=""
while (($#)); do
  case "$1" in
    --writepid) pidfile="$2"; shift 2;;
    --log) logfile="$2"; shift 2;;
    --config) config="$2"; shift 2;;
    *) shift;;
  esac
done
if [[ -n "${MOCK_FAIL_PROFILE:-}" && "$config" == *"$MOCK_FAIL_PROFILE"* ]]; then
  printf 'AUTH_FAILED\n' > "$logfile"
  exit 1
fi
counter_file="${OCX_TEST_IP_FILE}.counter"
n=$(cat "$counter_file" 2>/dev/null || printf 0)
n=$((n + 1))
printf '%s' "$n" > "$counter_file"
new="198.51.100.$((n % 200 + 1))"
printf '%s' "$new" > "$OCX_TEST_IP_FILE"
printf 'Initialization Sequence Completed\n' > "$logfile"
bash -c 'while :; do sleep 60; done' openvpn --config "$config" --writepid "$pidfile" >/dev/null 2>&1 &
echo $! >> "$MOCK_PIDS_FILE"
echo $! > "$pidfile"
exit 0
EOF

  cat > "$MOCK_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
set -e
cmd="${1:-}"; shift || true

if [[ "$cmd" == "models" ]]; then
  cat <<'MODELS'
opencode/deepseek-v4.1-flash-free
opencode/glm-5.3-flash-free
opencode/mimo-v2.6-flash-free
opencode/nemotron-3.5-lightning-free
opencode/big-pickle
MODELS
  exit 0
fi

if [[ "$cmd" == "run" ]]; then
  model=""
  while (($#)); do
    case "$1" in
      --model) model="$2"; shift 2;;
      --format) shift 2;;
      *) shift;;
    esac
  done
  if [[ "${MOCK_RUN_MODE:-normal}" == "toolfail" ]]; then
    printf '%s\n' '{"type":"tool_use","sessionID":"ses_mock","part":{"tool":"edit","state":{"status":"completed"}}}'
    printf '%s\n' '{"type":"error","sessionID":"ses_mock","error":{"type":"provider.quota","message":"Quota exceeded"}}'
    exit 1
  fi
  if [[ "${MOCK_RUN_MODE:-normal}" == "freelimit-once" ]]; then
    n=$(cat "$MOCK_FREE_LIMIT_FILE" 2>/dev/null || printf 0)
    n=$((n + 1))
    printf '%s' "$n" > "$MOCK_FREE_LIMIT_FILE"
    if (( n == 1 )); then
      printf '%s\n' '{"type":"error","sessionID":"ses_mock","error":{"type":"provider.quota","message":"Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go"}}'
      exit 1
    fi
    printf '%s\n' '{"type":"text","sessionID":"ses_mock","part":{"type":"text","text":"OK after VPN rotate"}}'
    exit 0
  fi
  if [[ "${MOCK_RUN_MODE:-normal}" == "freelimit-twice" ]]; then
    n=$(cat "$MOCK_FREE_LIMIT_FILE" 2>/dev/null || printf 0)
    n=$((n + 1))
    printf '%s' "$n" > "$MOCK_FREE_LIMIT_FILE"
    if (( n <= 2 )); then
      printf '%s\n' '{"type":"error","sessionID":"ses_mock","error":{"type":"provider.quota","message":"Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go"}}'
      exit 1
    fi
    printf '%s\n' '{"type":"text","sessionID":"ses_mock","part":{"type":"text","text":"OK after two VPN rotations"}}'
    exit 0
  fi
  if [[ "${MOCK_RUN_MODE:-normal}" == "freelimit-primary-always" ]]; then
    if [[ "$model" == *deepseek* ]]; then
      printf '%s\n' '{"type":"error","sessionID":"ses_mock","error":{"type":"provider.quota","message":"Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go"}}'
      exit 1
    fi
    printf '%s\n' '{"type":"text","sessionID":"ses_mock","part":{"type":"text","text":"OK from fallback"}}'
    exit 0
  fi
  if [[ "${MOCK_RUN_MODE:-normal}" == "timeout-once" ]]; then
    n=$(cat "$MOCK_TIMEOUT_FILE" 2>/dev/null || printf 0)
    n=$((n + 1))
    printf '%s' "$n" > "$MOCK_TIMEOUT_FILE"
    if (( n == 1 )); then
      sleep 5
    fi
    printf '%s\n' '{"type":"text","sessionID":"ses_mock","part":{"type":"text","text":"OK after timeout rotate"}}'
    exit 0
  fi
  if [[ "${MOCK_RUN_MODE:-normal}" == "freelimit-toolfail" ]]; then
    printf '%s\n' '{"type":"tool_use","sessionID":"ses_mock","part":{"tool":"edit","state":{"status":"completed"}}}'
    printf '%s\n' '{"type":"error","sessionID":"ses_mock","error":{"type":"provider.quota","message":"Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go"}}'
    exit 1
  fi
  case "$model" in
    *deepseek*)
      printf '%s\n' '{"type":"error","sessionID":"ses_mock","error":{"type":"provider.quota","message":"Quota exceeded for this model"}}'
      exit 1
      ;;
    *glm*)
      printf '%s\n' '{"type":"text","sessionID":"ses_mock","part":{"type":"text","text":"OK from fallback"}}'
      exit 0
      ;;
    *)
      printf '%s\n' '{"type":"text","sessionID":"ses_mock","part":{"type":"text","text":"OK from later fallback"}}'
      exit 0
      ;;
  esac
fi

if [[ "$cmd" == "api" ]]; then
  method="${1:-}"; path="${2:-}"; shift 2 || true
  payload=""
  while (($#)); do
    case "$1" in
      -d|--data) payload="$2"; shift 2;;
      *) shift;;
    esac
  done
  case "$method $path" in
    "get /api/info")
      printf '%s\n' '{"version":"mock"}'
      ;;
    "get /api/session/active")
      printf '%s\n' '{"data":{"ses_test":{}}}'
      ;;
    "get /api/session/ses_test")
      model="$(cat "$MOCK_MODEL_FILE")"
      provider="${model%%/*}"; id="${model#*/}"
      jq -n --arg p "$provider" --arg i "$id" \
        '{data:{model:{providerID:$p,id:$i,variant:"default"}}}'
      ;;
    "post /api/session/ses_test/model")
      model="$(jq -r '.model.providerID + "/" + .model.id' <<< "$payload")"
      printf '%s' "$model" > "$MOCK_MODEL_FILE"
      ;;
    "post /api/session")
      printf '%s\n' '{"data":{"id":"ses_new"}}'
      ;;
    *)
      printf 'mock opencode: unsupported api %s %s\n' "$method" "$path" >&2
      exit 1
      ;;
  esac
  exit 0
fi

exit 1
EOF

  chmod +x "$MOCK_BIN"/*
  export OCX_SUDO_BIN="$MOCK_BIN/sudo"
  export OCX_CURL_BIN="$MOCK_BIN/curl"
  export OCX_IP_BIN="$MOCK_BIN/ip"
  export OCX_WG_BIN="$MOCK_BIN/wg"
  export OCX_WG_QUICK_BIN="$MOCK_BIN/wg-quick"
  export OCX_OPENVPN_BIN="$MOCK_BIN/openvpn"
  export OCX_OPENCODE_BIN="$MOCK_BIN/opencode"
}

add_profile() {
  local region="$1" name="$2" kind="${3:-openvpn}"
  if [[ "$kind" == openvpn ]]; then
    printf 'client\n# test profile\n' > "$OCX_CONFIG_DIR/vpn/$region/$name.ovpn"
  else
    printf '[Interface]\nPrivateKey = test\n' > "$OCX_CONFIG_DIR/wireguard/$region/$name.conf"
  fi
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
printf 'ocx test suite\n'

new_env basic
make_mocks

run_capture "$OCX" version
assert_eq "$RC" 0 "version exits 0"
assert_contains "$OUTPUT" "ocx 0.2.0" "version prints version"

run_capture "$OCX" help
assert_contains "$OUTPUT" "ocx vpn" "help lists vpn"

# Models
run_capture "$OCX" models
assert_eq "$RC" 0 "models exits 0"
assert_contains "$OUTPUT" "deepseek-v4.1-flash-free" "models shows primary"
assert_contains "$OUTPUT" "bigpickle" "models shows alias"

# Model current/switch/next through mock API
run_capture "$OCX" model current
assert_eq "$RC" 0 "model current exits 0"
assert_contains "$OUTPUT" "opencode/deepseek-v4.1-flash-free" "model current shows model"

run_capture "$OCX" model switch glm
assert_eq "$RC" 0 "model switch exits 0"
assert_eq "$(cat "$MOCK_MODEL_FILE")" "opencode/glm-5.3-flash-free" "model switch updates session"

run_capture "$OCX" model next
assert_eq "$RC" 0 "model next exits 0"
assert_eq "$(cat "$MOCK_MODEL_FILE")" "opencode/mimo-v2.6-flash-free" "model next advances fallback"

run_capture "$OCX" fallback
assert_eq "$RC" 0 "fallback alias exits 0"
assert_eq "$(cat "$MOCK_MODEL_FILE")" "opencode/nemotron-3.5-lightning-free" "fallback alias advances model"

# model start dry-run
run_capture "$OCX" start --dry-run
assert_eq "$RC" 0 "start --dry-run exits 0"
assert_contains "$OUTPUT" "ses_new" "start dry-run prints session"
assert_contains "$OUTPUT" "opencode/deepseek-v4.1-flash-free" "start dry-run prints model"

# Run fallback success
run_capture "$OCX" run --fallback "hello"
assert_eq "$RC" 0 "run --fallback succeeds on retry"
assert_contains "$OUTPUT" "OK from fallback" "run --fallback prints fallback output"
assert_contains "$OUTPUT" "(2/5)" "run --fallback tries second model"

# Run fallback safety after a tool call
MOCK_RUN_MODE=toolfail
run_capture "$OCX" run --fallback "hello"
assert_eq "$RC" 1 "run --fallback returns 1 after tool call"
assert_contains "$OUTPUT" "KHÔNG tự retry" "run --fallback refuses unsafe retry"
assert_contains "$OUTPUT" "ocx model switch" "run --fallback prints recovery command"
MOCK_RUN_MODE=normal

run_capture "$OCX" run --vpn-region jp "hello"
assert_eq "$RC" 1 "--vpn-region requires --vpn-rotate"
assert_contains "$OUTPUT" "--vpn-region chỉ dùng cùng --vpn-rotate" "--vpn-region explains required flag"

# VPN OpenVPN
new_env vpn
make_mocks
add_profile vn vn-01
add_profile vn vn-02
add_profile jp jp-01

run_capture "$OCX" vpn list
assert_eq "$RC" 0 "vpn list exits 0"
assert_contains "$OUTPUT" "vn/vn-01" "vpn list shows vn-01"
assert_contains "$OUTPUT" "jp/jp-01" "vpn list shows jp-01"

run_capture "$OCX" vpn list --region jp
assert_contains "$OUTPUT" "jp/jp-01" "vpn list --region includes jp"
assert_not_contains "$OUTPUT" "vn/vn-01" "vpn list --region excludes vn"

run_capture "$OCX" vpn regions
assert_contains "$OUTPUT" "vn" "vpn regions shows vn"
assert_contains "$OUTPUT" "jp" "vpn regions shows jp"

run_capture "$OCX" vpn use does-not-exist
assert_eq "$RC" 1 "vpn use unknown profile fails"

run_capture "$OCX" vpn use vn-01
assert_eq "$RC" 0 "vpn use exits 0"
assert_contains "$(cat "$OCX_STATE_FILE")" "openvpn|vn/vn-01" "vpn use saves state"

run_capture "$OCX" vpn status
assert_eq "$RC" 0 "vpn status exits 0"
assert_contains "$OUTPUT" "Profile:      vn/vn-01" "vpn status shows profile"
assert_contains "$OUTPUT" "OpenVPN đang chạy" "vpn status sees process"

run_capture "$OCX" vpn use 3
assert_eq "$RC" 0 "vpn use numeric exits 0"
assert_contains "$(cat "$OCX_STATE_FILE")" "vn/vn-02" "vpn use numeric selects row"

run_capture "$OCX" vpn use 2
assert_eq "$RC" 0 "vpn use numeric 2 exits 0"
assert_contains "$(cat "$OCX_STATE_FILE")" "vn/vn-01" "vpn use numeric 2 selects vn-01"

run_capture "$OCX" vpn next --same-region
assert_eq "$RC" 0 "vpn next --same-region exits 0"
assert_contains "$(cat "$OCX_STATE_FILE")" "vn/vn-02" "vpn next --same-region stays in vn"

run_capture "$OCX" vpn next
assert_eq "$RC" 0 "vpn next exits 0"
assert_contains "$(cat "$OCX_STATE_FILE")" "jp/jp-01" "vpn next advances across regions"

run_capture "$OCX" vpn use vn-01
assert_eq "$RC" 0 "vpn use vn-01 again exits 0"
MOCK_FAIL_PROFILE="vn-02"
export MOCK_FAIL_PROFILE
run_capture "$OCX" vpn next
assert_eq "$RC" 0 "vpn next fails over"
assert_contains "$(cat "$OCX_STATE_FILE")" "jp/jp-01" "vpn next failover reaches jp"
unset MOCK_FAIL_PROFILE

# Free usage limit -> rotate VPN in current region -> retry same model
run_capture "$OCX" vpn use vn-01
assert_eq "$RC" 0 "vpn use before free-limit test exits 0"
MOCK_RUN_MODE=freelimit-once
export MOCK_RUN_MODE
: > "$MOCK_FREE_LIMIT_FILE"
run_capture "$OCX" run --fallback --vpn-rotate "hello"
assert_eq "$RC" 0 "run --fallback --vpn-rotate succeeds after VPN rotate"
assert_contains "$OUTPUT" "OK after VPN rotate" "run --fallback prints retry output"
assert_contains "$OUTPUT" "xoay VPN trong region hiện tại: vn" "free-limit rotation uses current region"
assert_contains "$(cat "$OCX_STATE_FILE")" "openvpn|vn/vn-02" "free-limit rotation advances within vn"

# Free usage limit sau tool call: tuyệt đối không tự xoay/retry
run_capture "$OCX" vpn use vn-01
assert_eq "$RC" 0 "vpn use before free-limit tool-call test exits 0"
MOCK_RUN_MODE=freelimit-toolfail
export MOCK_RUN_MODE
run_capture "$OCX" run --fallback --vpn-rotate "hello"
assert_eq "$RC" 1 "run --fallback --vpn-rotate stops after free-limit tool call"
assert_contains "$OUTPUT" "KHÔNG tự retry" "free-limit tool call refuses retry"
assert_contains "$(cat "$OCX_STATE_FILE")" "openvpn|vn/vn-01" "free-limit tool call does not rotate VPN"

# Free usage limit -> xoay trong region chỉ định
run_capture "$OCX" vpn use vn-01
: > "$MOCK_FREE_LIMIT_FILE"
MOCK_RUN_MODE=freelimit-once
export MOCK_RUN_MODE
run_capture "$OCX" run --fallback --vpn-rotate --vpn-region jp "hello"
assert_eq "$RC" 0 "run --fallback --vpn-rotate --vpn-region jp succeeds"
assert_contains "$OUTPUT" "xoay VPN trong region jp" "free-limit rotation uses explicit region"
assert_contains "$(cat "$OCX_STATE_FILE")" "openvpn|jp/jp-01" "free-limit rotation moves to jp"

# --vpn-rotate không bắt buộc --fallback; giữ nguyên model đã chọn
add_profile vn vn-03
run_capture "$OCX" vpn use vn-01
assert_eq "$RC" 0 "vpn use before no-fallback test exits 0"
: > "$MOCK_FREE_LIMIT_FILE"
MOCK_RUN_MODE=freelimit-once
export MOCK_RUN_MODE
run_capture "$OCX" run --vpn-rotate "hello"
assert_eq "$RC" 0 "run --vpn-rotate works without --fallback"
assert_contains "$OUTPUT" "OK after VPN rotate" "no-fallback rotate prints retry output"
assert_contains "$(cat "$OCX_STATE_FILE")" "openvpn|vn/vn-02" "no-fallback rotate advances to vn-02"

# Free limit lặp lại: xoay nhiều lần, vẫn giữ model
run_capture "$OCX" vpn use vn-01
: > "$MOCK_FREE_LIMIT_FILE"
MOCK_RUN_MODE=freelimit-twice
export MOCK_RUN_MODE
run_capture "$OCX" run --fallback --vpn-rotate --vpn-rotate-max 5 "hello"
assert_eq "$RC" 0 "run --vpn-rotate succeeds after two rotations"
assert_contains "$OUTPUT" "OK after two VPN rotations" "repeated rotation reaches model success"
assert_contains "$OUTPUT" "xoay VPN trong region hiện tại: vn (1/5)" "first rotation shows attempt count"
assert_contains "$OUTPUT" "xoay VPN trong region hiện tại: vn (2/5)" "second rotation shows attempt count"
assert_contains "$(cat "$OCX_STATE_FILE")" "openvpn|vn/vn-03" "repeated rotation advances to vn-03"

# Fixed model: không fallback sang model khác khi đã hết lượt xoay
run_capture "$OCX" vpn use vn-01
MOCK_RUN_MODE=freelimit-primary-always
export MOCK_RUN_MODE
run_capture "$OCX" run --fallback --vpn-rotate --vpn-rotate-max 1 "hello"
assert_eq "$RC" 1 "fixed-model mode stops after vpn max"
assert_contains "$OUTPUT" "giữ model cố định" "fixed-model mode explains no model fallback"
assert_not_contains "$OUTPUT" "OK from fallback" "fixed-model mode does not switch model"
assert_not_contains "$OUTPUT" "(2/" "fixed-model mode only runs selected model"
assert_contains "$(cat "$OCX_STATE_FILE")" "openvpn|vn/vn-02" "fixed-model mode still rotates VPN"

# Timeout model -> rotate VPN -> retry
run_capture "$OCX" vpn use vn-01
MOCK_RUN_MODE=timeout-once
export MOCK_RUN_MODE
run_capture "$OCX" run --fallback --vpn-rotate --run-timeout 1 "hello"
assert_eq "$RC" 0 "run --vpn-rotate recovers from model timeout"
assert_contains "$OUTPUT" "model không phản hồi (timeout)" "timeout is classified before retry"
assert_contains "$OUTPUT" "OK after timeout rotate" "timeout retry succeeds"
assert_contains "$(cat "$OCX_STATE_FILE")" "openvpn|vn/vn-02" "timeout rotation advances VPN"

# Profile lỗi khi xoay: tự chuyển profile kế tiếp
run_capture "$OCX" vpn use vn-01
: > "$MOCK_FREE_LIMIT_FILE"
MOCK_RUN_MODE=freelimit-once
MOCK_FAIL_PROFILE=vn-02
export MOCK_RUN_MODE MOCK_FAIL_PROFILE
run_capture "$OCX" run --fallback --vpn-rotate "hello"
assert_eq "$RC" 0 "run --vpn-rotate skips failed VPN profile"
assert_contains "$OUTPUT" "VPN vn/vn-02 không kết nối được" "failed VPN profile logs skip"
assert_contains "$(cat "$OCX_STATE_FILE")" "openvpn|vn/vn-03" "rotation continues to next profile"
unset MOCK_FAIL_PROFILE
MOCK_RUN_MODE=normal
export MOCK_RUN_MODE

run_capture "$OCX" vpn log 5
assert_eq "$RC" 0 "vpn log exits 0"

run_capture "$OCX" vpn disconnect
assert_eq "$RC" 0 "vpn disconnect exits 0"
[[ ! -e "$OCX_STATE_FILE" ]] && ok "vpn disconnect clears state" || bad "vpn disconnect clears state"

# VPN WireGuard
add_profile us us-01 wireguard
run_capture "$OCX" vpn use us-01
assert_eq "$RC" 0 "vpn use wireguard exits 0"
assert_contains "$(cat "$OCX_STATE_FILE")" "wireguard|us/us-01" "wireguard state saved"
run_capture "$OCX" vpn disconnect
assert_eq "$RC" 0 "wireguard disconnect exits 0"
[[ ! -e "$OCX_TEST_WG_FILE" ]] && ok "wireguard interface down" || bad "wireguard interface down"

# Import
new_env import
make_mocks
mkdir -p "$TMP/src/vpn_vn" "$TMP/src/japan" "$TMP/src/misc" "$TMP/src/us"
mkdir -p "$TMP/src/russian_federation" "$TMP/src/united_arab_emirates" "$TMP/src/united_state" "$TMP/src/wales" "$TMP/src/spain"
printf 'client\n' > "$TMP/src/vpn_vn/a.ovpn"
printf 'client\n' > "$TMP/src/japan/b.ovpn"
printf '[Interface]\nPrivateKey = x\n' > "$TMP/src/misc/us-02.conf"
printf 'client\n' > "$TMP/src/us/foo.ovpn"
printf 'client\n' > "$TMP/src/russian_federation/ru-profile.ovpn"
printf 'client\n' > "$TMP/src/united_arab_emirates/ae-profile.ovpn"
printf 'client\n' > "$TMP/src/united_state/us-profile.ovpn"
printf 'client\n' > "$TMP/src/wales/gb-profile.ovpn"
printf 'client\n' > "$TMP/src/spain/es-profile.ovpn"
run_capture "$OCX" vpn import "$TMP/src/vpn_vn" "$TMP/src/japan" "$TMP/src/misc/us-02.conf" "$TMP/src/us" "$TMP/src/russian_federation" "$TMP/src/united_arab_emirates" "$TMP/src/united_state" "$TMP/src/wales" "$TMP/src/spain"
assert_eq "$RC" 0 "vpn import exits 0"
[[ -f "$OCX_CONFIG_DIR/vpn/vn/a.ovpn" ]] && ok "import inferred vn" || bad "import inferred vn"
[[ -f "$OCX_CONFIG_DIR/vpn/jp/b.ovpn" ]] && ok "import inferred jp" || bad "import inferred jp"
[[ -f "$OCX_CONFIG_DIR/wireguard/us/us-02.conf" ]] && ok "import inferred wireguard us" || bad "import inferred wireguard us"
[[ -f "$OCX_CONFIG_DIR/vpn/us/foo.ovpn" ]] && ok "import keeps known directory region" || bad "import keeps known directory region"
[[ -f "$OCX_CONFIG_DIR/vpn/ru/ru-profile.ovpn" ]] && ok "import russian_federation as ru" || bad "import russian_federation as ru"
[[ -f "$OCX_CONFIG_DIR/vpn/ae/ae-profile.ovpn" ]] && ok "import united_arab_emirates as ae" || bad "import united_arab_emirates as ae"
[[ -f "$OCX_CONFIG_DIR/vpn/us/us-profile.ovpn" ]] && ok "import united_state as us" || bad "import united_state as us"
[[ -f "$OCX_CONFIG_DIR/vpn/gb/gb-profile.ovpn" ]] && ok "import wales as gb" || bad "import wales as gb"
[[ -f "$OCX_CONFIG_DIR/vpn/es/es-profile.ovpn" ]] && ok "import spain as es" || bad "import spain as es"

run_capture "$OCX" doctor
assert_eq "$RC" 0 "doctor exits 0"

printf '\nKết quả: %d pass, %d fail\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
