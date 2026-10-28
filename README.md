# ocx-bash-cli — OpenCode eXtended CLI

**Language:** **English** · [Tiếng Việt](README.vi.md)
**License:** [GPL-3.0](LICENSE)

`ocx` is a Bash CLI for Linux with two independent parts:

1. **VPN profile management** (OpenVPN `.ovpn`, WireGuard `.conf`): import, list,
   select, rotate sequentially/randomly/by region, fail over, check public IP.
2. **OpenCode model management**: model aliases, start a session with a given
   model, switch the model of a running session, and a guarded
   `ocx run --fallback`.

> **Important:** changing your IP through a VPN does **not** reset
> account/model quota. `ocx` does not use VPNs to evade usage limits. When you
> hit a quota, switch to a model/provider you are entitled to use. A VPN is
> only a way to manage network connectivity.

---

## 1. Project layout

```text
ocx-bash-cli/
├── bin/ocx                     # entrypoint
├── lib/
│   ├── common.sh               # config, state, logging, doctor
│   ├── vpn.sh                  # profiles, OpenVPN, WireGuard, rotation
│   └── models.sh               # model aliases, OpenCode API, fallback
├── config/
│   ├── ocx.conf.example
│   └── models.conf.example
├── completions/ocx.bash
├── vpn-profiles/               # profile store by region (contents ignored)
│   ├── README.md
│   ├── jp/.gitkeep
│   ├── vn/.gitkeep
│   └── ...
├── tests/run-tests.sh
├── install.sh
├── uninstall.sh
├── README.md                   # this file (English)
├── README.vi.md                # Vietnamese guide
└── LICENSE                     # GPL-3.0
```

After installation:

```text
~/.local/bin/ocx                         # symlink
~/.local/share/ocx/                      # code + lib
~/.config/ocx/
├── ocx.conf
├── models.conf
├── vpn/<region>/<name>.ovpn
└── wireguard/<region>/<name>.conf
~/.cache/ocx/                            # logs, cache, pidfile, lock
~/.local/state/ocx/                      # state, health history, limit/fail marks
```

---

## 2. Requirements

- Linux (Ubuntu/Debian recommended)
- OpenCode CLI installed and logged in to at least one provider
- `bash` >= 4.4, `curl`, `jq`, `sudo`, `timeout` (coreutils)
- OpenVPN if you use `.ovpn` profiles
- `wireguard-tools` if you use `.conf` profiles

Ubuntu/Debian:

```bash
sudo apt update
sudo apt install -y curl jq openvpn wireguard-tools
```

Check OpenCode:

```bash
opencode --version
opencode auth list
opencode models
```

---

## 3. Installation

Clone from GitHub:

```bash
git clone https://github.com/dinhvanit/ocx-bash-cli.git
cd ocx-bash-cli
./install.sh
```

Or, from inside the project directory:

```bash
./install.sh
```

The script will:

- install the code into `~/.local/share/ocx`;
- symlink `~/.local/bin/ocx`;
- create `~/.config/ocx/{ocx.conf,models.conf}` if missing;
- create the directories `vpn/vn`, `vpn/jp`, `vpn/us`, ...;
- install Bash completion.

If `~/.local/bin` is not on your `PATH`:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

Verify:

```bash
ocx doctor
ocx models
ocx vpn list
```

Re-run the installer:

```bash
./install.sh            # keep existing configuration
./install.sh --force    # overwrite models.conf/ocx.conf with the examples
```

---

## 4. Configuring OpenCode models

Open the file:

```bash
nano ~/.config/ocx/models.conf
```

The current example uses OpenCode free models:

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

- Model IDs must match `opencode models` or the `/models` screen.
- The free model list can change; run `ocx models --refresh` after OpenCode
  updates its catalog.
- You can add other providers if you have `/connect`ed them, e.g. OpenRouter or
  a local Ollama.

Show aliases and status:

```bash
ocx models
```

---

## 5. Managing VPN profiles

### 5.1 Importing profiles

From existing directories:

```bash
ocx vpn import ~/Workspace/test/vpn_vn --region vn
ocx vpn import ~/Workspace/test/japan --region jp
```

Import a single file, or rename it:

```bash
ocx vpn import ~/Downloads/foo.ovpn --region us --name us-gate-01
```

Import WireGuard:

```bash
ocx vpn import ~/Downloads/wg-us.conf --region us
```

If `--region` is omitted, `ocx` tries to infer it from the directory or file
name (`vpn_vn` → `vn`, `japan` → `jp`, `us-01` → `us`). When unsure, pass
`--region` explicitly.

The repository ships a `vpn-profiles/<region>/` directory for storing profile
copies. `.ovpn`/`.conf` files inside it are ignored by `.gitignore`; only
`.gitkeep` and `README.md` are committed. Import from this store:

```bash
ocx vpn import vpn-profiles/jp --region jp
ocx vpn import vpn-profiles/vn --region vn
```

### 5.2 Listing profiles

```bash
ocx vpn list
ocx vpn list --region jp
ocx vpn list --backend wireguard
ocx vpn regions
```

The `*` column marks the connected profile. `HEALTH` is the latest health check
result. The `MARK` column stores `ocx` bookkeeping:

- `limit/<age>`: the profile hit `Free usage limit reached`. This mark **expires
  automatically at 00:00 UTC** (start of the next UTC day), because free quota
  is usually refreshed daily.
- `fail/<age>`: the profile failed to connect. This mark expires after
  `OCX_VPN_FAIL_TTL` seconds (default 86400 = 24 hours), or is cleared as soon
  as the profile connects successfully.
- `-`: no mark; the profile will be tried during rotation.

The first column is an index; you can use it instead of long names:

```bash
ocx vpn use 3
ocx vpn test 3
```

Reset marks manually:

```bash
ocx vpn reset --limit          # clear quota marks, keep fail marks
ocx vpn reset --fail           # clear connection-failure marks
ocx vpn reset --all            # clear both
ocx vpn reset --limit --region vn
ocx vpn reset --limit vn/vn-01
```

`ocx run --vpn-rotate` only picks profiles that are **not marked** in the
rotation region. If every profile is marked, `ocx` stops and tells you to wait
for 00:00 UTC or reset the marks. If the current profile lets the model answer
successfully, its `limit`/`fail` mark is cleared.

### 5.3 Connecting and rotating

```bash
# Select exactly one profile (name or index)
ocx vpn use vn-01
ocx vpn use 3

# Next profile in the list (failover enabled by default)
ocx vpn next

# Random profile
ocx vpn random

# By region: rotate within region jp
ocx vpn region jp

# Rotate within the currently connected region only
ocx vpn next --same-region

# Try the list from the top, one by one
ocx vpn auto
```

Rotation order follows `ocx vpn list` (by region, then profile name). If the
current profile is the last one, `next` wraps around to the first.
`--same-region` takes the region from the profile managed by `ocx`; if no VPN is
active, use `--region R`.

`OCX_FAILOVER=1` is the default: if the selected profile does not come up or its
health check fails, `ocx` tries the next profile until the list is exhausted.
Disable it:

```bash
ocx vpn next --no-failover
ocx vpn use vn-01 --no-failover
```

Test a profile and then disconnect:

```bash
ocx vpn test jp-01
ocx vpn test jp-01 --keep
```

### 5.4 Status and logs

```bash
ocx vpn status
ocx vpn log 100
```

`vpn status` shows:

- the current public IPv4 address;
- backend, profile, file, and connection time;
- current `limit`/`fail` marks (if any);
- whether the OpenVPN process or WireGuard interface is still alive;
- the latest health check.

### 5.5 Disconnecting

```bash
ocx vpn disconnect
ocx vpn disconnect --all
```

`ocx` only manages processes/interfaces it created itself:

- OpenVPN: uses its own pidfile and verifies the command line before signalling.
- WireGuard: only brings down interfaces belonging to profiles inside the `ocx`
  directory.
- It never runs `pkill openvpn`, and never touches VPNs you started outside
  `ocx`.

`--all` additionally scans OpenVPN processes using profiles under
`~/.config/ocx/vpn` and tears down the matching WireGuard interfaces.

### 5.6 How health checks work

After the backend starts, `ocx`:

1. waits for `Initialization Sequence Completed` in the OpenVPN log, or for the
   WireGuard interface to appear;
2. calls each endpoint in `OCX_HEALTH_URLS` in turn to fetch the public IPv4;
3. compares it with the IP captured before connecting;
4. records the result in `~/.local/state/ocx/vpn-health.tsv`.

Connection failures and exhausted-quota profiles are stored separately in
`~/.local/state/ocx/vpn-marks.tsv` (the `MARK` column in `vpn list`).

By default an unchanged IP is only a **warning**, not a failure. To treat it as
a failure:

```bash
OCX_REQUIRE_IP_CHANGE=1 ocx vpn next
```

or set it in `~/.config/ocx/ocx.conf`.

Free VPN Gate servers are often dead or overloaded. Failover helps try other
profiles automatically, but cannot guarantee that every profile works.

---

## 6. Model fallback for OpenCode

### 6.1 Starting a new session with a given model

```bash
ocx start                 # primary
ocx start glm             # alias glm
ocx start --auto          # first model currently present in the catalog
ocx start --mini glm      # mini UI
ocx start --dry-run glm   # print session/model only, do not open the TUI
```

`ocx start` creates a session through the OpenCode API with the selected model,
then opens the TUI with `opencode --session <id>`. The model therefore applies
immediately, without editing `opencode.json`.

If the OpenCode API does not respond, `ocx` opens the default TUI and warns you.

### 6.2 Switching the model of a running session

From another terminal (or from the same machine):

```bash
ocx model current
ocx model switch glm
ocx model next
ocx fallback          # short alias for model next
```

- No `--session` is needed when there is only one active session, or when the
  `OPENCODE_SESSION_ID` variable is set.
- With multiple sessions:

```bash
ocx model switch glm --session ses_xxx
```

This calls `POST /api/session/<id>/model`; OpenCode uses the new model for
subsequent turns and keeps the session context. It is the most practical way to
"rescue" a session in progress when the old model runs out of quota. If the
`opencode models` cache says the next model does not exist in the catalog, `ocx`
skips it and picks the one after; without a cache it follows the exact order.

### 6.3 Running a prompt with fallback

```bash
ocx run -m primary "Refactor the parseToken function"
ocx run --fallback "Refactor the parseToken function"
```

When OpenCode reports a free usage limit:

```text
Error: Free usage limit reached. Free models work in OpenCode
(https://opencode.ai); subscribe to OpenCode Go to keep going:
https://opencode.ai/go
```

you can ask `ocx` to keep the same model, rotate the VPN, and retry until the
model answers:

```bash
# Keep the deepseek model, rotate within the current region
ocx run --fallback --vpn-rotate "Refactor the parseToken function"

# --fallback is not required; --vpn-rotate enables the guarded mode itself
ocx run --vpn-rotate "Refactor the parseToken function"

# Rotate within region jp only
ocx run --fallback --vpn-rotate --vpn-region jp "Refactor the parseToken function"

# At most 50 rotations; each VPN wait is capped at 20 seconds
ocx run --vpn-rotate --vpn-rotate-max 50 --vpn-timeout 20 "Refactor the parseToken function"

# Treat a model that does not answer within 120s as a timeout and rotate
ocx run --vpn-rotate --run-timeout 120 "Refactor the parseToken function"
```

Mechanics:

- **the selected model stays fixed** (`-m` or primary); in `--vpn-rotate` mode
  it never falls back to another model;
- it rotates on an exact `free_limit` error, an `opencode run` timeout, or a
  network error;
- it **never rotates/retries once a tool call has happened**;
- each rotation tries one profile; a failed/timed-out profile moves straight to
  the next one instead of waiting for the whole region's failover;
- on `free_limit`, the profile in use is marked `limit`; on connection failure
  it is marked `fail`. Later rotations skip marked profiles;
- `limit` marks expire at 00:00 UTC; `fail` marks expire after
  `OCX_VPN_FAIL_TTL` (default 24h) or when the profile reconnects successfully;
- rotation is capped at `--vpn-rotate-max` attempts (default 20; `0` = unlimited);
- each connect/IP check has a `--vpn-timeout` limit (default 30s);
- each OpenCode call has a `--run-timeout` limit (default 180s; `0` = off);
- the current region is kept unless `--vpn-region` is passed;
- a changed public IP is required (`OCX_REQUIRE_IP_CHANGE=1` during rotation);
- it stops at the first VPN where the model answers successfully; if attempts
  run out and it still fails, it stops without switching models.

You can enable this by default in `~/.config/ocx/ocx.conf`:

```bash
OCX_RUN_VPN_ON_FREE_LIMIT=1
# OCX_RUN_VPN_REGION="vn"       # optional; empty = keep the current region
OCX_RUN_VPN_MAX=20              # 0 = unlimited
OCX_RUN_VPN_TIMEOUT=30          # per connect/IP-check timeout
OCX_RUN_TIMEOUT=180             # per OpenCode call timeout; 0 = off
OCX_VPN_FAIL_TTL=86400          # skip failing profiles for 24h; 0 = keep until reset
```

`--fallback` runs `opencode run --format json`, reads the events, and only
retries when:

- the error belongs to **quota**, **model unavailable**, or **rate limit**
  (rate limit only when `OCX_RUN_FALLBACK_ON_RATE_LIMIT=1`);
- **no tool call has happened** during that run.

If the model already called a tool (reading/editing files, running commands),
`ocx` **does not retry automatically**, because side effects may exist. Instead
it prints:

```text
ocx model switch <next-model> --session <session-id>
opencode --session <session-id>
```

Inspect `git diff`/`git status`, then switch the model for that session.

Error groups:

| Group | Action |
| --- | --- |
| `free_limit` (Free usage limit reached) | rotate the VPN repeatedly when `--vpn-rotate` is on; keep the model, stop when it answers or attempts run out |
| `quota` (usage limit, exhausted, billing...) | fall back if no tool call has happened |
| `unavailable` (model not found/no-route) | fall back if no tool call has happened |
| `rate` (429) | no fallback by default; enable `OCX_RUN_FALLBACK_ON_RATE_LIMIT=1` if desired |
| `auth` | stop; check `opencode auth list` / `/connect` |
| `network` | stop unless `--vpn-rotate` is on; if on, rotate and retry |
| `timeout` | stop unless `--vpn-rotate` is on; if on, rotate and retry |
| `context` | stop; use `/compact` or a model with a larger context |

### 6.4 Current limitations

- VPN rotation is **opt-in**, only active with `--vpn-rotate` or
  `OCX_RUN_VPN_ON_FREE_LIMIT=1`; it applies to free usage limits, timeouts, and
  network errors before any tool call. It does not guarantee that account quota
  is refreshed.
- Repeated rotation can take time. Use `--vpn-rotate-max`, `--vpn-timeout`, and
  `--run-timeout` to bound it; `Ctrl-C` stops immediately.
- If an OpenVPN instance not managed by `ocx` is running, `ocx` stops before
  rotating to avoid stacked tunnels; shut that VPN down first.
- It cannot detect quota **inside a running TUI**. Use `ocx model next` from
  another terminal, or `/models` in the TUI.
- It never replays a prompt that already produced a tool call.
- It cannot read remaining quota; most providers expose no standard API.
- `ocx start` creates a new session; it does not resume an old one.

---

## 7. Beyond VPN Gate + OpenVPN

`ocx` also supports **WireGuard**. Other options worth considering:

| Approach | Pros | Notes |
| --- | --- | --- |
| WireGuard (`wg-quick`) | light, fast, more stable than OpenVPN | needs a `.conf` file; already supported by `ocx` |
| ProtonVPN/Windscribe/Mullvad WireGuard | more stable servers than VPN Gate | own account/limits; follow their terms |
| Cloudflare WARP (`warp-cli`) | easy, free | few profiles/regions; could be integrated later |
| Tailscale exit node | uses your own device/VPS | needs a device acting as exit node |
| Self-hosted WireGuard/OpenVPN VPS | controlled IP, high stability | costs money, needs administration |
| SSH SOCKS5 (`ssh -D`) | quick per-command egress change | not a global VPN; requires proxy configuration |
| HTTP/SOCKS5 proxy | flexible for HTTP clients | OpenCode/providers may ignore proxies |

VPN Gate is fine for quick experiments but should not be treated as stable
infrastructure. For long-lived connections, WireGuard to a VPS or a reputable
paid provider is a better choice.

---

## 8. `ocx.conf` configuration

```bash
nano ~/.config/ocx/ocx.conf
```

Main variables:

```bash
OCX_CONNECT_TIMEOUT=60
OCX_IP_TIMEOUT=30
OCX_SUDO=ask                 # ask | none
OCX_FAILOVER=1
OCX_CHECK_UNMANAGED_VPN=1     # block connect if an external OpenVPN is running
OCX_REQUIRE_IP_CHANGE=0
OCX_MODELS_CACHE_TTL=300
OCX_RUN_FALLBACK_ON_RATE_LIMIT=0
OCX_RUN_VPN_ON_FREE_LIMIT=0
OCX_RUN_VPN_REGION=""
OCX_RUN_VPN_MAX=20             # 0 = unlimited
OCX_RUN_VPN_TIMEOUT=30         # per connect/IP-check timeout
OCX_RUN_TIMEOUT=180            # per OpenCode call timeout; 0 = off
OCX_VPN_FAIL_TTL=86400         # skip failing profiles for 24h; 0 = keep until reset
```

- `OCX_SUDO=none` is only for setups where permissions are configured
  appropriately (e.g. running as root); the default `ask` invokes `sudo`.
- `OCX_MODELS_CACHE_TTL` is how long `opencode models` is cached.
- `OCX_RUN_VPN_ON_FREE_LIMIT=1` enables automatic VPN rotation when `ocx run`
  hits a free usage limit/timeout/network error; an empty `OCX_RUN_VPN_REGION`
  means keep the current region.
- `OCX_RUN_VPN_MAX`, `OCX_RUN_VPN_TIMEOUT`, and `OCX_RUN_TIMEOUT` bound the
  number of rotations and the wait times; command-line flags override them.
- `OCX_VPN_FAIL_TTL` is how long connection-failed profiles are skipped; set it
  to `0` to keep fail marks until `ocx vpn reset --fail` or a successful
  reconnect.
- Rotating the VPN does not refresh account quota; it only changes the egress
  IP. If the provider still reports the quota as exhausted, use another
  model/provider you are entitled to.

---

## 9. Troubleshooting

```bash
ocx doctor
ocx vpn status
ocx vpn log 100
sudo tail -n 100 ~/.cache/ocx/log/openvpn-*.log
curl -4 https://api.ipify.org
```

### The VPN does not come up

- Check that the `.ovpn` file is still valid and points to the right server.
- VPN Gate servers can be offline; try `ocx vpn next`.
- Read the OpenVPN log.
- Check DNS/routes; some profiles do not route IPv4.
- If `ocx vpn status` reports an unchanged IP, the tunnel may not be routing
  traffic.

### "Detected an OpenVPN not managed by ocx"

You have an OpenVPN session running outside `ocx` (e.g. an old
`sudo openvpn --config ...` command). `ocx` will not kill it, to avoid breaking
a connection you rely on. Stop it first:

- go back to the terminal running OpenVPN and press `Ctrl-C`, or
- `sudo kill <PID>` (find the PID with `ps -eo pid,args | grep '[o]penvpn'`).

Then run `ocx vpn next` again. To tear down tunnels created by `ocx` itself, use
`ocx vpn disconnect --all`.

### `ocx vpn use` cannot confirm the IP

- The IP-check endpoints are blocked; try changing `OCX_HEALTH_URLS`.
- The VPN is slow; increase `OCX_CONNECT_TIMEOUT`/`OCX_IP_TIMEOUT`.
- The profile only routes IPv6 or is split-tunnel.

### The OpenCode API does not respond

```bash
opencode service status
opencode service restart
opencode api get /api/info
```

### The model is not in the catalog

```bash
opencode models
ocx models --refresh
```

Update `~/.config/ocx/models.conf` with the real IDs.

### `ocx model switch` reports multiple sessions

```bash
ocx model switch glm --session ses_xxx
```

### `ocx start` opens the default TUI

Creating the session through the API failed. Check `opencode service` and retry,
or use `/models` in the TUI.

---

## 10. Security

- `.ovpn`/`.conf` files usually contain certificates/private keys. Keep them
  `600`.
- Do not run unknown scripts with `sudo`.
- `ocx` uses `sudo openvpn`/`wg-quick` because creating tunnels/routes requires
  privileges.
- `ocx` never runs `pkill openvpn`; it only affects processes with its own
  pidfile/state, or profiles inside its config directory.
- Never put API keys in `models.conf`; OpenCode manages credentials separately.

---

## 11. Uninstalling

```bash
./uninstall.sh              # keep configuration/profiles
./uninstall.sh --purge      # also remove config, cache, state, profiles
```

---

## 12. Tests

The suite uses mocks; it does not touch the network or burn quota:

```bash
./tests/run-tests.sh
```

Current result: 130 pass, 0 fail.

---

## 13. Quick reference

```bash
# Install
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

# Models
ocx models
ocx start
ocx start glm
ocx model current
ocx model next
ocx fallback
ocx run --fallback --vpn-rotate "your prompt"
ocx run --vpn-rotate --vpn-rotate-max 50 --vpn-timeout 20 "your prompt"
ocx run --fallback --vpn-rotate --vpn-region jp "your prompt"

# Diagnostics
ocx doctor
```

---

## 14. License

This project is released under the **GNU General Public License v3.0**
(GPL-3.0).

- Full license text: [`LICENSE`](LICENSE)
- Canonical page at the FSF: <https://www.gnu.org/licenses/gpl-3.0.html>
- Standalone text (easier to read, no "how to apply" appendix):
  <https://www.gnu.org/licenses/gpl-3.0-standalone.html>
- Why not the LGPL: <https://www.gnu.org/licenses/why-not-lgpl.html>

Rights and obligations at a glance:

| Right | Condition |
| --- | --- |
| Run the program for any purpose | Unrestricted |
| Study and modify the source | Must publish source when distributing modified versions |
| Distribute copies | Include the license, keep copyright notices, add no restrictions |
| Distribute modified versions | Mark changes, license the whole derivative work under GPL-3.0 |
| Sell copies/support | Allowed, as long as the freedoms above are preserved |

Main obligations:

- Provide the **Corresponding Source** to anyone who receives a compiled or
  packaged version.
- Keep copyright notices and **add no further restrictions** on recipients'
  rights.
- If you modify the code, **state that you changed it** and do not misrepresent
  the original author.
- Do not sublicense under a different license.
- The program is provided **"AS IS"**, without warranty; the authors are not
  liable for damages (sections 15–17).

To apply it to your own code, see *How to Apply These Terms* at the end of
[`LICENSE`](LICENSE), or use this short NOTICE template:

```text
ocx-bash-cli — OpenCode eXtended CLI
Copyright (C) 2026 dinhvanit

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
```

---

## 15. Useful links

**OpenCode**

- Website: <https://opencode.ai>
- Docs: <https://opencode.ai/docs>
- Models/pricing: <https://opencode.ai/docs/models>
- OpenCode Go (paid plan): <https://opencode.ai/go>
- Source code: <https://github.com/sst/opencode>
- Discord: <https://opencode.ai/discord>

**VPNs and tooling**

- VPN Gate (free server list): <https://www.vpngate.net>
- OpenVPN: <https://openvpn.net/community/>
- WireGuard: <https://www.wireguard.com>
- `wg-quick`: <https://man7.org/linux/man-pages/man8/wg-quick.8.html>
- Cloudflare WARP: <https://developers.cloudflare.com/warp-client/>
- Tailscale exit nodes: <https://tailscale.com/kb/1103/exit-nodes>
- ProtonVPN: <https://protonvpn.com>
- Mullvad: <https://mullvad.net>
- Windscribe: <https://windscribe.com>

**This project**

- Source: <https://github.com/dinhvanit/ocx-bash-cli>
- Issues: <https://github.com/dinhvanit/ocx-bash-cli/issues>
- Discussions: <https://github.com/dinhvanit/ocx-bash-cli/discussions>

**License and Bash references**

- GNU GPL v3.0: <https://www.gnu.org/licenses/gpl-3.0.html>
- GPL FAQ: <https://www.gnu.org/licenses/gpl-faq.html>
- Bash Reference Manual: <https://www.gnu.org/software/bash/manual/>
- ShellCheck: <https://www.shellcheck.net>
- jq manual: <https://jqlang.github.io/jq/manual/>
