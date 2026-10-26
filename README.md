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
├── vpn-profiles/               # kho profile theo region (nội dung bị ignore)
│   ├── README.md
│   ├── jp/.gitkeep
│   ├── vn/.gitkeep
│   └── ...
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
~/.local/state/ocx/                      # state, health history, mark limit/fail
```

---

## 2. Yêu cầu

- Linux (Ubuntu/Debian khuyến nghị)
- OpenCode CLI đã cài và đã đăng nhập provider
- `bash` >= 4.4, `curl`, `jq`, `sudo`, `timeout` (coreutils)
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

Trong dự án có sẵn thư mục `vpn-profiles/<region>/` để lưu bản sao profile.
Các file `.ovpn`/`.conf` trong đó bị `.gitignore` chặn; chỉ `.gitkeep` và
`README.md` được commit. Import từ kho này:

```bash
ocx vpn import vpn-profiles/jp --region jp
ocx vpn import vpn-profiles/vn --region vn
```

### 5.2 Xem danh sách

```bash
ocx vpn list
ocx vpn list --region jp
ocx vpn list --backend wireguard
ocx vpn regions
```

Cột `*` là profile đang kết nối. `HEALTH` là kết quả kiểm tra gần nhất.
Cột `MARK` lưu đánh dấu của `ocx`:

- `limit/<tuổi>`: profile đã gặp `Free usage limit reached`. Mark này **tự hết
  hạn sau 0h UTC** (sang ngày UTC mới), vì thường quota free được làm mới theo
  ngày.
- `fail/<tuổi>`: profile kết nối lỗi. Mark này hết hạn sau
  `OCX_VPN_FAIL_TTL` giây (mặc định 86400 = 24 giờ), hoặc được xoá ngay khi
  profile kết nối lại thành công.
- `-`: chưa có mark, profile sẽ được thử khi xoay.

Cột đầu là số thứ tự; có thể dùng số này thay cho tên dài:

```bash
ocx vpn use 3
ocx vpn test 3
```

Reset mark thủ công:

```bash
ocx vpn reset --limit          # xoá mark hết quota, giữ mark fail
ocx vpn reset --fail           # xoá mark kết nối lỗi
ocx vpn reset --all            # xoá cả hai
ocx vpn reset --limit --region vn
ocx vpn reset --limit vn/vn-01
```

`ocx run --vpn-rotate` chỉ chọn các profile **chưa bị mark** trong region xoay.
Nếu tất cả đã bị mark, `ocx` dừng và báo chờ 0h UTC hoặc reset. Profile đang
dùng mà model trả lời thành công sẽ được xoá mark `limit`/`fail`.

### 5.3 Kết nối và xoay

```bash
# Chọn đúng một profile (tên hoặc số thứ tự)
ocx vpn use vn-01
ocx vpn use 3

# Profile kế tiếp trong danh sách (mặc định có failover)
ocx vpn next

# Ngẫu nhiên
ocx vpn random

# Theo vùng: xoay trong region jp
ocx vpn region jp

# Xoay trong đúng region đang kết nối, không nhảy sang region khác
ocx vpn next --same-region

# Thử lần lượt từ đầu danh sách
ocx vpn auto
```

Thứ tự xoay là thứ tự trong `ocx vpn list` (theo vùng rồi tên profile). Nếu
profile hiện tại là profile cuối, `next` quay lại profile đầu. `--same-region`
lấy region từ profile đang được `ocx` quản lý; nếu chưa có VPN active, hãy dùng
`--region R`.

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
- mark `limit`/`fail` hiện tại (nếu có);
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

Profile lỗi kết nối và profile hết quota được lưu riêng trong
`~/.local/state/ocx/vpn-marks.tsv` (cột `MARK` khi `vpn list`).

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

Khi gặp lỗi free usage limit của OpenCode:

```text
Error: Free usage limit reached. Free models work in OpenCode
(https://opencode.ai); subscribe to OpenCode Go to keep going:
https://opencode.ai/go
```

có thể cho `ocx` giữ nguyên model, tự xoay VPN và thử lại cho đến khi model
phản hồi:

```bash
# Giữ model deepseek, xoay trong region hiện tại
ocx run --fallback --vpn-rotate "Refactor hàm parseToken"

# Không cần --fallback; --vpn-rotate tự bật chế độ chạy có kiểm soát
ocx run --vpn-rotate "Refactor hàm parseToken"

# Chỉ xoay trong region jp
ocx run --fallback --vpn-rotate --vpn-region jp "Refactor hàm parseToken"

# Tối đa 50 lần xoay; mỗi lần chờ VPN tối đa 20 giây
ocx run --vpn-rotate --vpn-rotate-max 50 --vpn-timeout 20 "Refactor hàm parseToken"

# Model không phản hồi quá 120 giây thì coi là timeout và xoay VPN
ocx run --vpn-rotate --run-timeout 120 "Refactor hàm parseToken"
```

Cơ chế:

- **giữ cố định model đã chọn** (`-m` hoặc primary); không tự fallback sang
  model khác trong chế độ `--vpn-rotate`;
- xoay khi gặp đúng `free_limit`, khi `opencode run` timeout, hoặc lỗi mạng;
- tuyệt đối **không xoay/retry nếu đã có tool call**;
- mỗi lần xoay thử một profile; profile lỗi/timeout thì chuyển ngay profile kế
  tiếp, không chờ hết failover của cả region;
- khi gặp `free_limit`, profile đang dùng được đánh dấu `limit`; khi kết nối
  lỗi, profile được đánh dấu `fail`. Các lần xoay sau bỏ qua profile đã mark;
- mark `limit` tự hết hạn sau 0h UTC; mark `fail` hết hạn sau
  `OCX_VPN_FAIL_TTL` (mặc định 24h) hoặc khi kết nối lại thành công;
- xoay tối đa `--vpn-rotate-max` lần (mặc định 20; `0` = không giới hạn);
- mỗi lần kết nối/kiểm tra IP có timeout `--vpn-timeout` (mặc định 30 giây);
- mỗi lần gọi OpenCode có timeout `--run-timeout` (mặc định 180 giây; `0` = tắt);
- mặc định giữ region hiện tại, trừ khi truyền `--vpn-region`;
- yêu cầu IP public phải đổi (`OCX_REQUIRE_IP_CHANGE=1` cho lần xoay);
- dừng ở VPN đầu tiên mà model trả lời thành công; nếu hết lượt xoay mà vẫn
  lỗi thì dừng, không đổi model.

Có thể bật mặc định trong `~/.config/ocx/ocx.conf`:

```bash
OCX_RUN_VPN_ON_FREE_LIMIT=1
# OCX_RUN_VPN_REGION="vn"       # tùy chọn; để trống = giữ region hiện tại
OCX_RUN_VPN_MAX=20              # 0 = không giới hạn
OCX_RUN_VPN_TIMEOUT=30          # timeout mỗi lần kết nối/kiểm tra IP
OCX_RUN_TIMEOUT=180             # timeout mỗi lần gọi OpenCode; 0 = tắt
OCX_VPN_FAIL_TTL=86400          # bỏ qua profile lỗi trong 24h; 0 = giữ đến khi reset
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
| `free_limit` (Free usage limit reached) | xoay VPN lặp lại nếu bật `--vpn-rotate`; giữ nguyên model, dừng khi model trả lời hoặc hết lượt |
| `quota` (usage limit, exhausted, billing...) | fallback nếu chưa có tool call |
| `unavailable` (model not found/no-route) | fallback nếu chưa có tool call |
| `rate` (429) | mặc định không fallback; bật `OCX_RUN_FALLBACK_ON_RATE_LIMIT=1` nếu muốn |
| `auth` | dừng, kiểm tra `opencode auth list` / `/connect` |
| `network` | dừng nếu không bật `--vpn-rotate`; nếu bật thì xoay VPN và thử lại |
| `timeout` | dừng nếu không bật `--vpn-rotate`; nếu bật thì xoay VPN và thử lại |
| `context` | dừng, dùng `/compact` hoặc model context lớn hơn |

### 6.4 Giới hạn hiện tại

- Xoay VPN là **opt-in**, chỉ chạy khi bật `--vpn-rotate` hoặc
  `OCX_RUN_VPN_ON_FREE_LIMIT=1`; áp dụng cho free usage limit, timeout và lỗi
  mạng trước khi có tool call. Không đảm bảo quota tài khoản được làm mới.
- Xoay VPN lặp lại có thể mất thời gian. Dùng `--vpn-rotate-max`,
  `--vpn-timeout`, `--run-timeout` để giới hạn; `Ctrl-C` để dừng ngay.
- Nếu có OpenVPN không do `ocx` quản lý, `ocx` dừng trước khi xoay để tránh
  chồng tunnel; hãy tắt VPN đó trước.
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
OCX_RUN_VPN_ON_FREE_LIMIT=0
OCX_RUN_VPN_REGION=""
OCX_RUN_VPN_MAX=20             # 0 = không giới hạn
OCX_RUN_VPN_TIMEOUT=30         # timeout mỗi lần kết nối/kiểm tra IP
OCX_RUN_TIMEOUT=180            # timeout mỗi lần gọi OpenCode; 0 = tắt
OCX_VPN_FAIL_TTL=86400         # bỏ qua profile lỗi trong 24h; 0 = giữ đến khi reset
```

- `OCX_SUDO=none` chỉ dùng khi bạn đã cấu hình quyền phù hợp (ví dụ chạy bằng
  root); mặc định `ask` sẽ gọi `sudo`.
- `OCX_MODELS_CACHE_TTL` là thời gian cache `opencode models`.
- `OCX_RUN_VPN_ON_FREE_LIMIT=1` bật tự xoay VPN khi `ocx run` gặp free usage
  limit/timeout/lỗi mạng; `OCX_RUN_VPN_REGION` để trống nghĩa là giữ region
  hiện tại.
- `OCX_RUN_VPN_MAX`, `OCX_RUN_VPN_TIMEOUT`, `OCX_RUN_TIMEOUT` giới hạn số lần
  xoay và thời gian chờ; có thể override bằng cờ dòng lệnh.
- `OCX_VPN_FAIL_TTL` là thời gian bỏ qua profile bị lỗi kết nối; đặt `0` nếu
  muốn giữ mark fail cho đến khi `ocx vpn reset --fail` hoặc kết nối lại thành
  công.
- Xoay VPN không làm mới quota tài khoản; đây chỉ là thay đổi egress IP. Nếu
  provider vẫn báo hết quota, hãy dùng model/provider khác mà bạn có quyền.

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

Kết quả hiện tại: 130 pass, 0 fail.

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
ocx vpn next --same-region
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
ocx run --fallback --vpn-rotate "your prompt"
ocx run --vpn-rotate --vpn-rotate-max 50 --vpn-timeout 20 "your prompt"
ocx run --fallback --vpn-rotate --vpn-region jp "your prompt"

# Chẩn đoán
ocx doctor
```
