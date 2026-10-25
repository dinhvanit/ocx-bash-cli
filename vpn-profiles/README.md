# vpn-profiles — kho profile VPN trong dự án

Thư mục này chứa bản sao profile VPN để quản lý tập trung trong dự án.

- `.gitkeep` được commit để giữ cấu trúc thư mục region.
- Toàn bộ file `.ovpn`, `.conf`, certificate, key và credential bên trong
  **bị ignore**, không được đưa lên GitHub.
- File profile thật nằm trên máy bạn, quyền `600`.

## Cấu trúc

```text
vpn-profiles/
├── README.md
├── ae/.gitkeep          # united_arab_emirates (chưa có file)
├── au/.gitkeep          # australia
├── ca/                  # canada
├── es/                  # spain
├── gb/                  # wales / United Kingdom
├── id/                  # indonesia
├── jp/                  # japan
├── kr/                  # korea
├── misc/                # profile lỗi/không xác định region
├── ph/.gitkeep          # philippines
├── ru/                  # russian_federation
├── sg/.gitkeep          # singapore
├── th/                  # thailand
├── tw/.gitkeep          # taiwan
├── uk/.gitkeep          # alias United Kingdom -> gb khi import
├── us/.gitkeep          # united_state (chưa có file)
└── vn/                  # vietnam
```

Mỗi thư mục region có một `.gitkeep`; các file `.ovpn` nằm cạnh đó nhưng bị
`.gitignore` chặn.

## Import vào ocx

`ocx` không đọc trực tiếp thư mục này. Hãy import vào cấu hình thật:

```bash
# Một region
ocx vpn import vpn-profiles/jp --region jp
ocx vpn import vpn-profiles/vn --region vn

# Tất cả region (ocx tự suy ra region từ tên thư mục)
ocx vpn import vpn-profiles

# File lẻ
ocx vpn import vpn-profiles/jp/ten-file.ovpn --region jp
```

Sau đó kiểm tra:

```bash
ocx vpn list
ocx vpn regions
```

Profile được copy vào:

```text
~/.config/ocx/vpn/<region>/
~/.config/ocx/wireguard/<region>/
```

## Thêm region mới

```bash
mkdir -p vpn-profiles/de
touch vpn-profiles/de/.gitkeep
# copy file .ovpn vào vpn-profiles/de/
ocx vpn import vpn-profiles/de --region de
```

## Kiểm tra không commit nhầm profile

```bash
git status --short
git check-ignore -v vpn-profiles/jp/*.ovpn
git check-ignore -v vpn-profiles/jp/.gitkeep
```

Kết quả đúng:

- file `.ovpn` bị ignore;
- file `.gitkeep` **không** bị ignore.

Không dùng `git add -f vpn-profiles/**/*.ovpn`.
