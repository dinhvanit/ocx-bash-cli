#!/usr/bin/env bash
# Gỡ ocx. Mặc định giữ cấu hình và profile VPN.
set -Eeuo pipefail

SHARE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/ocx"
BIN_DIR="${PREFIX:-$HOME/.local}/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ocx"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ocx"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ocx"
BASH_COMPLETION="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions/ocx"

PURGE=0
YES=0
while (($#)); do
  case "$1" in
    --purge) PURGE=1; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help)
      cat <<'EOF'
Cách dùng: ./uninstall.sh [--purge] [--yes]

  --purge   Xoá cả cấu hình, cache, state và profile VPN.
  --yes     Không hỏi xác nhận khi --purge.
EOF
      exit 0
      ;;
    *) echo "tham số không hợp lệ: $1" >&2; exit 1 ;;
  esac
done

if [[ -L "$BIN_DIR/ocx" ]]; then
  target="$(readlink -f "$BIN_DIR/ocx" 2>/dev/null || true)"
  case "$target" in
    "$SHARE_DIR"/*) rm -f "$BIN_DIR/ocx" ;;
    *) echo "Không xoá $BIN_DIR/ocx vì không trỏ tới $SHARE_DIR" ;;
  esac
elif [[ -f "$BIN_DIR/ocx" ]]; then
  echo "Giữ $BIN_DIR/ocx vì không phải symlink do install.sh tạo."
fi

rm -rf "$SHARE_DIR" "$BASH_COMPLETION"
echo "Đã xoá code ocx."

if (( PURGE )); then
  if (( YES == 0 )); then
    read -r -p "Xoá cả cấu hình/profile trong $CONFIG_DIR? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Giữ cấu hình."; exit 0; }
  fi
  rm -rf "$CONFIG_DIR" "$CACHE_DIR" "$STATE_DIR"
  echo "Đã xoá cấu hình, cache và state."
else
  echo "Giữ cấu hình: $CONFIG_DIR"
  echo "Dùng --purge nếu muốn xoá cả profile VPN."
fi
