# vpn-profiles (thư mục staging)

Đây chỉ là thư mục mẫu để bạn để tạm file `.ovpn`/`.conf` trước khi import.
`ocx` **không** đọc trực tiếp thư mục này.

Import vào cấu hình thật:

```bash
ocx vpn import ./vpn-profiles/vn-01.ovpn --region vn
ocx vpn import ./vpn-profiles/jp-01.ovpn --region jp
ocx vpn import ./vpn-profiles/us-01.conf --region us
```

Sau khi import:

- OpenVPN: `~/.config/ocx/vpn/<region>/<name>.ovpn`
- WireGuard: `~/.config/ocx/wireguard/<region>/<name>.conf`

Kiểm tra:

```bash
ocx vpn list
ocx vpn regions
```
