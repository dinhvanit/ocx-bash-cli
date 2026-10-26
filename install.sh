#!/usr/bin/env bash
# Cài ocx vào ~/.local (không cần root).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/ocx"
BIN_DIR="${PREFIX:-$HOME/.local}/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ocx"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ocx"
BASH_COMPLETION_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions"

FORCE=0
SKIP_CONFIG=0
while (($#)); do
  case "$1" in
    --force|-f) FORCE=1; shift ;;
    --no-config) SKIP_CONFIG=1; shift ;;
    -h|--help)
      cat <<'EOF'
Cách dùng: ./install.sh [--force] [--no-config]

  --force       Ghi đè file cấu hình mẫu (models.conf, ocx.conf).
  --no-config   Không tạo/cập nhật file cấu hình.

Cài code vào ~/.local/share/ocx và symlink ~/.local/bin/ocx.
EOF
      exit 0
      ;;
    *) echo "tham số không hợp lệ: $1" >&2; exit 1 ;;
  esac
done

install -d -m 755 "$SHARE_DIR/bin" "$SHARE_DIR/lib" "$BIN_DIR"
install -m 755 "$SCRIPT_DIR/bin/ocx" "$SHARE_DIR/bin/ocx"
install -m 644 "$SCRIPT_DIR"/lib/*.sh "$SHARE_DIR/lib/"

if [[ -e "$BIN_DIR/ocx" && ! -L "$BIN_DIR/ocx" ]]; then
  mv "$BIN_DIR/ocx" "$BIN_DIR/ocx.bak.$(date +%s)"
  echo "Đã sao lưu ocx cũ trong $BIN_DIR"
fi
ln -sfn "$SHARE_DIR/bin/ocx" "$BIN_DIR/ocx"

if (( SKIP_CONFIG == 0 )); then
  install -d -m 700 "$CONFIG_DIR" "$CONFIG_DIR/vpn" "$CONFIG_DIR/wireguard"
  for region in vn jp us sg kr tw hk misc; do
    install -d -m 700 "$CONFIG_DIR/vpn/$region" "$CONFIG_DIR/wireguard/$region"
  done

  install_config() {
    local src="$1" dest="$2"
    if [[ -e "$dest" ]] && ! (( FORCE )); then
      echo "Giữ cấu hình hiện có: $dest"
      return 0
    fi
    install -m 600 "$src" "$dest"
    echo "Đã tạo: $dest"
  }
  install_config "$SCRIPT_DIR/config/models.conf.example" "$CONFIG_DIR/models.conf"
  install_config "$SCRIPT_DIR/config/ocx.conf.example" "$CONFIG_DIR/ocx.conf"
fi

install -d -m 755 "$BASH_COMPLETION_DIR"
install -m 644 "$SCRIPT_DIR/completions/ocx.bash" "$BASH_COMPLETION_DIR/ocx"

echo
echo "Đã cài ocx vào: $SHARE_DIR"
echo "Lệnh:           $BIN_DIR/ocx"
echo "Cấu hình:       $CONFIG_DIR"
echo

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo "Thêm vào ~/.bashrc nếu $BIN_DIR chưa có trong PATH:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
    echo
    ;;
esac

missing=()
for c in opencode curl jq sudo timeout; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if ((${#missing[@]} > 0)); then
  echo "Thiếu lệnh: ${missing[*]}"
  echo "Ubuntu/Debian: sudo apt install -y curl jq openvpn wireguard-tools"
  echo
fi

cat <<EOF
Bước tiếp theo:
  1. Kiểm tra:        ocx doctor
  2. Import VPN:      ocx vpn import ~/Workspace/test/vpn_vn --region vn
                      ocx vpn import ~/Workspace/test/japan --region jp
  3. Xem profile:     ocx vpn list
  4. Nối VPN:         ocx vpn next
  5. Xem model:       ocx models
  6. Mở OpenCode:     ocx start
EOF
