# ocx-bash-cli — OpenCode eXtended CLI

`ocx` là CLI Bash cho Linux, gồm hai phần độc lập:

1. **Quản lý VPN profile** (OpenVPN `.ovpn`, WireGuard `.conf`): import, liệt kê,
   chọn, xoay tuần tự/ngẫu nhiên/theo vùng, failover, kiểm tra IP public.
2. **Quản lý model OpenCode**: alias model, mở phiên với model chỉ định, chuyển
   model của phiên đang chạy, và `ocx run --fallback` có kiểm soát an toàn.

> **Quan trọng:** đổi IP qua VPN **không** làm mới quota tài khoản/model. `ocx`
> không dùng VPN để né hạn mức. Khi hết quota, hãy chuyển sang model/provider
> mà bạn có quyền sử dụng. VPN chỉ dùng để quản lý kết nối mạng.

---

## 1. Cấu trúc dự án

```text
ocx-bash-cli/
├── bin/ocx                     # entrypoint
├── lib/
│   ├── common.sh               # cấu hình, state, log, doctor
│   ├── vpn.sh                  # profile, OpenVPN, WireGuard, rotation
│   └── models.sh               # model alias, OpenCode API, fallback
├── config/
│   ├── ocx.conf.example
│   └── models.conf.example
├── completions/ocx.bash
├── tests/run-tests.sh
├── install.sh
├── uninstall.sh
└── README.md
```

Sau khi cài:

```text
~/.local/bin/ocx                         # symlink
~/.local/share/ocx/                      # code + lib
~/.config/ocx/
├── ocx.conf
├── models.conf
├── vpn/<region>/<name>.ovpn
└── wireguard/<region>/<name>.conf
~/.cache/ocx/                            # log, cache, pidfile, lock
~/.local/state/ocx/                      # state, health history
```

---

## 2. Yêu cầu

- Linux (Ubuntu/Debian khuyến nghị)
- OpenCode CLI đã cài và đã đăng nhập provider
- `bash` >= 4.4, `curl`, `jq`, `sudo`
- OpenVPN nếu dùng `.ovpn`
- `wireguard-tools` nếu dùng `.conf`

Ubuntu/Debian:

```bash
sudo apt update
sudo apt install -y curl jq openvpn wireguard-tools
```

Kiểm tra OpenCode:

```bash
opencode --version
opencode auth list
opencode models
```

---

## 3. Cài đặt

Clone từ GitHub:

```bash
git clone https://github.com/dinhvanit/ocx-bash-cli.git
cd ocx-bash-cli
./install.sh
```

Hoặc nếu đang đứng trong thư mục dự án:

```bash
./install.sh
```

Script sẽ:

- cài code vào `~/.local/share/ocx`;
- symlink `~/.local/bin/ocx`;
- tạo `~/.config/ocx/{ocx.conf,models.conf}` nếu chưa có;
- tạo các thư mục `vpn/vn`, `vpn/jp`, `vpn/us`, ...
- cài Bash completion.

Nếu `~/.local/bin` chưa có trong `PATH`:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

Kiểm tra:

```bash
ocx doctor
ocx models
ocx vpn list
```

Chạy lại installer:

```bash
./install.sh            # giữ cấu hình hiện có
./install.sh --force    # ghi đè models.conf/ocx.conf bằng file mẫu
```

---

## 4. Cấu hình model OpenCode

Mở file:

```bash
nano ~/.config/ocx/models.conf
```

Mẫu hiện tại dùng các model free của OpenCode:

```bash
OCX_MODEL_PRIMARY="opencode/deepseek-v4.1-flash-free"

OCX_MODEL_FALLBACKS=(
  "opencode/glm-5.3-flash-free"
  "opencode/mimo-v2.6-flash-free"
  "opencode/nemotron-3.5-lightning-free"
  "opencode/big-pickle"
)

declare -A OCX_MODEL_ALIASES=(
  ["primary"]="$OCX_MODEL_PRIMARY"
  ["glm"]="opencode/glm-5.3-flash-free"
  ["mimo"]="opencode/mimo-v2.6-flash-free"
  ["nemotron"]="opencode/nemotron-3.5-lightning-free"
  ["bigpickle"]="opencode/big-pickle"
)

OCX_MODEL_ORDER=(primary glm mimo nemotron bigpickle)
```

- Model ID phải khớp `opencode models` hoặc màn hình `/models`.
- Danh sách model free có thể thay đổi; chạy `ocx models --refresh` sau khi
  OpenCode cập nhật catalog.
- Có thể thêm provider khác nếu đã `/connect`, ví dụ OpenRouter, Ollama local.

Xem alias và trạng thái:

```bash
ocx models
```

---

## 5. Quản lý VPN profile

### 5.1 Import profile

Từ các thư mục hiện có:

```bash
ocx vpn import ~/Workspace/test/vpn_vn --region vn
ocx vpn import ~/Workspace/test/japan --region jp
```

Import một file hoặc đổi tên:

```bash
ocx vpn import ~/Downloads/foo.ovpn --region us --name us-gate-01
```

Import WireGuard:

```bash
ocx vpn import ~/Downloads/wg-us.conf --region us
```

Nếu không truyền `--region`, `ocx` cố suy ra từ tên thư mục hoặc tên file
(`vpn_vn` → `vn`, `japan` → `jp`, `us-01` → `us`). Nếu không chắc, hãy truyền
`--region`.

### 5.2 Xem danh sách

```bash
ocx vpn list
ocx vpn list --region jp
ocx vpn list --backend wireguard
ocx vpn regions
```

Cột `*` là profile đang kết nối. `HEALTH` là kết quả kiểm tra gần nhất.
Cột đầu là số thứ tự; có thể dùng số này thay cho tên dài:

```bash
ocx vpn use 3
ocx vpn test 3
```

### 5.3 Kết nối và xoay

```bash
# Chọn đúng một profile (tên hoặc số thứ tự)
ocx vpn use vn-01
ocx vpn use 3

# Profile kế tiếp trong danh sách (mặc định có failover)
ocx vpn next

# Ngẫu nhiên
ocx vpn random

# Theo vùng
ocx vpn region jp

# Thử lần lượt từ đầu danh sách
ocx vpn auto
```

Thứ tự xoay là thứ tự trong `ocx vpn list` (theo vùng rồi tên profile). Nếu
profile hiện tại là profile cuối, `next` quay lại profile đầu.

Mặc định `OCX_FAILOVER=1`: nếu profile được chọn không lên hoặc health check
thất bại, `ocx` thử profile kế tiếp cho đến hết danh sách. Tắt:

```bash
ocx vpn next --no-failover
ocx vpn use vn-01 --no-failover
```

Kiểm tra một profile rồi ngắt:

```bash
ocx vpn test jp-01
ocx vpn test jp-01 --keep
```

### 5.4 Trạng thái và log

```bash
ocx vpn status
ocx vpn log 100
```

`vpn status` hiển thị:

- IPv4 public hiện tại;
- backend, profile, file, thời điểm kết nối;
- process OpenVPN hoặc interface WireGuard còn sống không;
- health check gần nhất.

### 5.5 Ngắt kết nối

```bash
ocx vpn disconnect
ocx vpn disconnect --all
```

`ocx` chỉ quản lý process/interface do chính nó tạo:

- OpenVPN: dùng pidfile riêng và kiểm tra command line trước khi gửi tín hiệu.
- WireGuard: chỉ hạ interface của profile trong thư mục `ocx`.
- Không chạy `pkill openvpn`, không đụng VPN bạn tự khởi động ngoài `ocx`.

`--all` quét thêm các process OpenVPN dùng profile nằm trong
`~/.config/ocx/vpn` và hạ các WireGuard interface tương ứng.

### 5.6 Health check hoạt động thế nào?

Sau khi backend khởi động, `ocx`:

1. chờ log OpenVPN có `Initialization Sequence Completed`, hoặc interface
   WireGuard xuất hiện;
2. gọi lần lượt các endpoint trong `OCX_HEALTH_URLS` để lấy IPv4 public;
3. so sánh với IP trước khi kết nối;
4. ghi kết quả vào `~/.local/state/ocx/vpn-health.tsv`.

Mặc định IP không đổi chỉ là **cảnh báo**, không fail. Muốn coi là fail:

```bash
OCX_REQUIRE_IP_CHANGE=1 ocx vpn next
```

hoặc đặt trong `~/.config/ocx/ocx.conf`.

VPN Gate miễn phí thường có server chết/quá tải. Failover giúp tự thử profile
khác, nhưng không đảm bảo mọi profile đều hoạt động.

---

## 6. Model fallback cho OpenCode

### 6.1 Mở phiên mới với model chỉ định

```bash
ocx start                 # primary
ocx start glm             # alias glm
ocx start --auto          # model đầu tiên đang có trong catalog
ocx start --mini glm      # giao diện mini
ocx start --dry-run glm   # chỉ in session/model, không mở TUI
```

`ocx start` tạo một session qua API OpenCode với model đã chọn, sau đó mở TUI
bằng `opencode --session <id>`. Nhờ vậy model được áp dụng ngay, không cần
sửa `opencode.json`.

Nếu API OpenCode không phản hồi, `ocx` mở TUI mặc định và cảnh báo.

### 6.2 Chuyển model trong phiên đang chạy

Từ terminal khác (hoặc từ chính máy):

```bash
ocx model current
ocx model switch glm
ocx model next
ocx fallback          # alias ngắn của model next
```

- Không cần `--session` nếu chỉ có một phiên active, hoặc biến
  `OPENCODE_SESSION_ID` đang được đặt.
- Nếu có nhiều phiên:

```bash
ocx model switch glm --session ses_xxx
```

Lệnh này gọi API `POST /api/session/<id>/model`; OpenCode sẽ dùng model mới cho
các lượt tiếp theo, giữ nguyên context của session. Đây là cách thực tế nhất để
"cứu" một phiên đang dở khi model cũ hết quota. Nếu cache `opencode models`
cho biết model kế tiếp không tồn tại trong catalog, `ocx` bỏ qua và chọn model
sau đó; nếu chưa có cache, nó chuyển theo đúng thứ tự.

### 6.3 Chạy prompt có fallback

```bash
ocx run -m primary "Refactor hàm parseToken"
ocx run --fallback "Refactor hàm parseToken"
```

`--fallback` chạy `opencode run --format json`, đọc event và chỉ retry khi:

- lỗi thuộc nhóm **quota**, **model unavailable**, hoặc **rate limit** (rate
  limit chỉ khi bật `OCX_RUN_FALLBACK_ON_RATE_LIMIT=1`);
- **chưa có tool call nào** trong lần chạy đó.

Nếu model đã gọi tool (đọc/sửa file, chạy lệnh...), `ocx` **không tự retry** vì
có thể đã tạo hiệu ứng phụ. Thay vào đó nó in:

```text
ocx model switch <model-kế-tiếp> --session <session-id>
opencode --session <session-id>
```

Bạn kiểm tra `git diff`/`git status`, rồi chuyển model cho đúng session đó.

Các nhóm lỗi:

| Nhóm | Hành động |
| --- | --- |
| `quota` (usage limit, exhausted, billing...) | fallback nếu chưa có tool call |
| `unavailable` (model not found/no-route) | fallback nếu chưa có tool call |
| `rate` (429) | mặc định không fallback; bật `OCX_RUN_FALLBACK_ON_RATE_LIMIT=1` nếu muốn |
| `auth` | dừng, kiểm tra `opencode auth list` / `/connect` |
| `network` | dừng, kiểm tra mạng/VPN |
| `context` | dừng, dùng `/compact` hoặc model context lớn hơn |

### 6.4 Giới hạn hiện tại

- Không tự phát hiện quota **bên trong TUI đang chạy**. Bạn dùng
  `ocx model next` từ terminal khác, hoặc `/models` trong TUI.
- Không tự replay prompt đã có tool call.
- Không đọc được số quota còn lại; hầu hết provider không có API chuẩn.
- `ocx start` tạo session mới; không resume session cũ.

---

## 7. Ngoài VPN Gate + OpenVPN

`ocx` hiện hỗ trợ thêm **WireGuard**. Ngoài ra có thể cân nhắc:

| Cách | Ưu điểm | Lưu ý |
| --- | --- | --- |
| WireGuard (`wg-quick`) | nhẹ, nhanh, ổn định hơn OpenVPN | cần file `.conf`; `ocx` đã hỗ trợ |
| ProtonVPN/Windscribe/Mullvad WireGuard | server ổn định hơn VPN Gate | tài khoản/giới hạn riêng; chỉ dùng theo điều khoản |
| Cloudflare WARP (`warp-cli`) | dễ dùng, miễn phí | không có nhiều profile/region; có thể tích hợp sau |
| Tailscale exit node | dùng thiết bị/VPS của bạn | cần thiết bị làm exit node |
| VPS tự dựng WireGuard/OpenVPN | kiểm soát IP, độ ổn định cao | tốn chi phí, cần quản trị |
| SSH SOCKS5 (`ssh -D`) | nhanh để đổi egress cho một số lệnh | không phải VPN toàn cục; cần cấu hình proxy |
| HTTP/SOCKS5 proxy | linh hoạt cho HTTP client | OpenCode/provider có thể không tôn trọng proxy |

VPN Gate phù hợp để thử nhanh, nhưng không nên xem là hạ tầng ổn định. Nếu cần
kết nối lâu dài, WireGuard tới VPS hoặc nhà cung cấp trả phí đáng tin cậy hơn.

---

## 8. Cấu hình `ocx.conf`

```bash
nano ~/.config/ocx/ocx.conf
```

Các biến chính:

```bash
OCX_CONNECT_TIMEOUT=60
OCX_IP_TIMEOUT=30
OCX_SUDO=ask                 # ask | none
OCX_FAILOVER=1
OCX_CHECK_UNMANAGED_VPN=1     # chặn nối nếu có OpenVPN ngoài ocx
OCX_REQUIRE_IP_CHANGE=0
OCX_MODELS_CACHE_TTL=300
OCX_RUN_FALLBACK_ON_RATE_LIMIT=0
```

- `OCX_SUDO=none` chỉ dùng khi bạn đã cấu hình quyền phù hợp (ví dụ chạy bằng
  root); mặc định `ask` sẽ gọi `sudo`.
- `OCX_MODELS_CACHE_TTL` là thời gian cache `opencode models`.

---

## 9. Troubleshooting

```bash
ocx doctor
ocx vpn status
ocx vpn log 100
sudo tail -n 100 ~/.cache/ocx/log/openvpn-*.log
curl -4 https://api.ipify.org
```

### VPN không lên

- Kiểm tra file `.ovpn` còn hạn/đúng server không.
- VPN Gate server có thể offline; thử `ocx vpn next`.
- Xem log OpenVPN.
- Kiểm tra DNS/route; một số profile không route IPv4.
- `ocx vpn status` báo IP không đổi: có thể tunnel chưa route traffic.

### Báo “phát hiện OpenVPN không do ocx quản lý”

Bạn đang có một phiên OpenVPN chạy ngoài `ocx` (ví dụ lệnh `sudo openvpn
--config ...` cũ). `ocx` không tự kill process này để tránh phá kết nối bạn
đang dùng. Hãy dừng nó trước:

- quay lại terminal đang chạy OpenVPN và nhấn `Ctrl-C`, hoặc
- `sudo kill <PID>` (xem PID bằng `ps -eo pid,args | grep '[o]penvpn'`).

Sau đó chạy lại `ocx vpn next`. Nếu muốn tắt các tunnel do chính `ocx` tạo:
`ocx vpn disconnect --all`.

### `ocx vpn use` không xác nhận được IP

- Endpoint kiểm tra IP bị chặn; thử đổi `OCX_HEALTH_URLS`.
- VPN chậm; tăng `OCX_CONNECT_TIMEOUT`/`OCX_IP_TIMEOUT`.
- Profile chỉ route IPv6 hoặc split-tunnel.

### OpenCode API không phản hồi

```bash
opencode service status
opencode service restart
opencode api get /api/info
```

### Model không có trong catalog

```bash
opencode models
ocx models --refresh
```

Sửa `~/.config/ocx/models.conf` theo ID thực tế.

### `ocx model switch` báo nhiều phiên

```bash
ocx model switch glm --session ses_xxx
```

### `ocx start` mở TUI mặc định

API tạo session thất bại. Kiểm tra `opencode service` và thử lại; hoặc dùng
`/models` trong TUI.

---

## 10. Bảo mật

- File `.ovpn`/`.conf` thường chứa certificate/private key. Giữ quyền `600`.
- Không chạy script lạ bằng `sudo`.
- `ocx` dùng `sudo openvpn`/`wg-quick` vì cần quyền tạo tunnel/route.
- `ocx` không chạy `pkill openvpn`; chỉ tác động process có pidfile/state hoặc
  profile nằm trong thư mục cấu hình của nó.
- Không đưa API key vào `models.conf`; OpenCode quản lý credential riêng.

---

## 11. Gỡ cài đặt

```bash
./uninstall.sh              # giữ cấu hình/profile
./uninstall.sh --purge      # xoá cả cấu hình, cache, state, profile
```

---

## 12. Test

Bộ test dùng mock, không gọi mạng thật, không đốt quota:

```bash
./tests/run-tests.sh
```

Kết quả hiện tại: 58 pass, 0 fail.

---

## 13. Lệnh nhanh

```bash
# Cài
./install.sh

# VPN
ocx vpn import ~/Workspace/test/vpn_vn --region vn
ocx vpn import ~/Workspace/test/japan --region jp
ocx vpn list
ocx vpn next
ocx vpn region jp
ocx vpn status
ocx vpn log 100
ocx vpn disconnect

# Model
ocx models
ocx start
ocx start glm
ocx model current
ocx model next
ocx fallback
ocx run --fallback "your prompt"

# Chẩn đoán
ocx doctor
```
