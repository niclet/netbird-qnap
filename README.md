# Netbird QPKG for QNAP NAS

A build pipeline that produces a native QNAP package (QPKG) for the [Netbird](https://netbird.io/) WireGuard-based mesh VPN client. The QPKG installs Netbird directly on the QNAP host OS rather than running it inside Docker.

## Why not Docker?

QNAP's Container Station (Docker) environment locks down kernel interfaces that Netbird requires to function:

- `/proc/sys` is mounted read-only, preventing sysctl tuning
- `iptables` and `nftables` are not exposed to containers
- Network namespace restrictions block WireGuard tunnel creation

This causes the Netbird client to crash with `"no firewall manager found"` and similar errors related to missing kernel facilities. Running natively on the QNAP host gives the Netbird client full access to the kernel networking stack, WireGuard, and firewall management -- exactly what it needs to create and maintain mesh VPN tunnels.

## How it works

The QPKG wraps a statically-linked Netbird client binary with a QNAP service script. When installed:

1. The Netbird binary is placed on the NAS filesystem
2. A configuration file is created where you set your setup key, management URL, and other options
3. A service script handles starting and stopping Netbird through QNAP's standard service management

Netbird runs as a background daemon, connecting your QNAP NAS to your Netbird mesh network. It creates a WireGuard tunnel interface and manages routes, DNS, and firewall rules natively on the host.

## Project structure

```
netbird-qnap/
  README.md                          # This file
  qpkg/
    qpkg.cfg                         # QPKG metadata (name, version, author, etc.)
    package_routines                 # QDK install/remove hooks
    icons/
      netbird_80.png                 # QPKG icon for QNAP App Center (80x80)
      netbird_gray.png               # Disabled state icon
    shared/
      netbird.sh                     # Service start/stop/restart script
      netbird.conf                   # User-editable configuration file
    x86_64/
      netbird                        # Statically-linked Netbird client binary
  src/                               # Upstream netbird source (cloned from netbirdio/netbird)
  .github/
    workflows/
      build.yml                      # CI workflow: check version, build, package, release
```

## CI/CD pipeline

The pipeline runs on GitHub Actions:

### Build workflow (`build.yml`)

Triggered on push to `main`, on a schedule (to pick up upstream Netbird releases), or manually via `workflow_dispatch`.

1. **Check upstream version** -- Queries the latest Netbird release tag from `github.com/netbirdio/netbird`. Compares against the last version this repo built. Skips the build if the version has not changed (unless forced).
2. **Clone upstream source** -- Shallow-clones the upstream Netbird repo at the target release tag into `src/`.
3. **Build the binary** -- Compiles the Netbird client with:
   ```
   CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o netbird ./client/
   ```
   This produces a fully static binary that runs on any Linux kernel without external library dependencies -- critical for QNAP's minimal userland.
4. **Package the QPKG** -- Assembles the binary, service script, config file, and metadata into a `.qpkg` archive using QNAP's QDK (QPKG Development Kit) tooling.
5. **Upload artifact** -- Stores the built `.qpkg` file as a workflow artifact for the release job to consume.

### Release (integrated into build workflow)

After a successful build of a new upstream version, the workflow automatically:

1. **Create release** -- Creates a GitHub release tagged with the upstream version.
2. **Upload QPKG** -- Attaches the `.qpkg` file to the release as a downloadable asset.
3. **Generate checksum** -- Produces a SHA-256 checksum file alongside the QPKG for verification.

### Runner labels

All jobs use `ubuntu-latest` (standard GitHub-hosted runner). No specialized hardware is needed since the Go cross-compilation produces a static binary on any Linux host.

### Secrets

| Secret | Purpose |
|--------|---------|
| `GITHUB_TOKEN` | Automatically provided by GitHub Actions for creating releases and uploading assets |

### Upstream tracking

The build workflow runs on a schedule (daily or weekly cron) to check for new Netbird releases. When a new upstream tag is detected that has not already been built and released, the pipeline automatically triggers a build-and-release cycle. The version scheme mirrors upstream: if Netbird releases `v0.35.1`, this project releases `v0.35.1` with the corresponding QPKG.

You can also force a rebuild at any time via `workflow_dispatch`, optionally specifying a particular upstream version to build.

## Installation

### Prerequisites

- A QNAP NAS running QTS (x86_64 architecture)
- SSH access to the NAS (for initial setup) or the QNAP web UI
- A Netbird account with a setup key (from [app.netbird.io](https://app.netbird.io/) or your self-hosted management server)

### Option A: Add the app repository (recommended, auto-updates)

1. In the QNAP web UI, open **App Center**
2. Click the gear icon (upper right) and go to **App Repository**
3. Add this URL:
   ```
   https://zachhandley.github.io/netbird-qnap/repo.xml
   ```
4. Netbird VPN will appear in your App Center -- install it from there
5. Future updates are automatic through the App Center

### Option B: Manual install

1. Download the latest `.qpkg` file from the [Releases](../../releases) page.
2. In the QNAP web UI, open **App Center** and click **Install Manually** (the gear icon in the upper right).
3. Browse to the downloaded `.qpkg` file and install it.

Alternatively, via SSH:

```bash
# Copy the .qpkg to your NAS
scp netbird_*.qpkg admin@your-nas-ip:/tmp/

# SSH into the NAS and install
ssh admin@your-nas-ip
sh /tmp/netbird_*.qpkg
```

### Configure

Open **Netbird VPN** from the QTS desktop (or browse to `/netbird/` on the NAS). Every
option below is on that page. At minimum, paste a setup key and press **Save & Restart**.

To configure over SSH instead, edit the same file the settings page writes:

```bash
ssh admin@your-nas-ip
vi /etc/config/qpkg/netbird/netbird.conf
```

```
SETUP_KEY=your-netbird-setup-key-here
```

See the [Configuration reference](#configuration-reference) below for all available options.

### Start the service

Start Netbird from the QNAP web UI (App Center, find Netbird, click Start) or via SSH:

```bash
/etc/init.d/netbird.sh start
```

### Verify

Check that Netbird is running and connected:

```bash
/etc/config/qpkg/netbird/netbird status
```

Look at the `Management:` line, not the first line. The first line is the *daemon* status,
which reads `Connected` whenever the daemon process is alive — including while the peer
cannot reach the management server at all.

You should see your NAS appear in your Netbird dashboard at [app.netbird.io](https://app.netbird.io/) (or your self-hosted management UI).

## How settings are applied

Editing `netbird.conf` — from the settings page or by hand — does nothing until the service
restarts. The restart is what applies them, and it does so in a specific order:

```
netbird down
netbird up --management-url … --setup-key … --allow-server-ssh=true …
```

The `down` is mandatory. `netbird up` returns early with `Already connected`, **before** it
sends any configuration to the daemon, whenever the daemon reports itself connected — and
the daemon auto-connects from its stored profile the moment it starts. Without the `down`,
every setting is silently discarded and `netbird up` still exits 0, so a stale management
URL survives restart after restart while the package reports success.

Settings are passed as explicit command-line flags rather than `NB_*` environment variables,
so this file, not the daemon's stored profile, decides what the peer connects to.

If a start fails, the reason is written to `/etc/config/qpkg/netbird/last-error` and shown on
the settings page. The full log is `/var/log/netbird-service.log`.

## Configuration reference

The configuration file is `/etc/config/qpkg/netbird/netbird.conf`. It is registered as a QPKG
config file, so package upgrades preserve your edits instead of overwriting them.

**Booleans take `true` or `false`, and empty means "leave Netbird's current setting alone" —
not "off".** Netbird only applies a flag that was explicitly passed, and it treats a
never-configured SSH server as *enabled*, so blanking `ALLOW_SERVER_SSH` will not disable it.
Set `false` to actually turn something off.

### Connection

| Option | Required | `netbird up` flag | Description |
|--------|----------|-------------------|-------------|
| `SETUP_KEY` | Yes | `--setup-key` | Setup key from your Netbird dashboard. Needed to register this peer. |
| `MANAGEMENT_URL` | No | `--management-url` | Management server URL, scheme included. Defaults to `https://api.netbird.io:443` (Netbird's hosted service). |
| `ADMIN_URL` | No | `--admin-url` | Admin dashboard URL. Self-hosted only. |
| `HOSTNAME` | No | `--hostname` | Peer name. Defaults to the NAS system hostname. |
| `PRESHARED_KEY` | No | `--preshared-key` | WireGuard pre-shared key. Only peers sharing it can communicate. |

`MANAGEMENT_URL` must include `https://` or `http://`. Prefer `https://`: pointing a `http://`
URL at a TLS-terminating reverse proxy makes the proxy answer the gRPC call with a redirect,
and Netbird reports it as `unexpected HTTP status code received from server: 308 (Permanent
Redirect); malformed header: missing HTTP content-type`.

### Logging

| Option | Description |
|--------|-------------|
| `LOG_LEVEL` | `panic`, `fatal`, `error`, `warn`, `info`, `debug`, `trace`. Defaults to `info`. |
| `LOG_FILE` | Daemon log path. Defaults to `/var/log/netbird.log`. |

### SSH server

Netbird's built-in SSH server, reachable from other peers with `netbird ssh <peer>`.

| Option | `netbird up` flag |
|--------|-------------------|
| `ALLOW_SERVER_SSH` | `--allow-server-ssh` |
| `ENABLE_SSH_ROOT` | `--enable-ssh-root` |
| `ENABLE_SSH_SFTP` | `--enable-ssh-sftp` |
| `ENABLE_SSH_LOCAL_PORT_FORWARDING` | `--enable-ssh-local-port-forwarding` |
| `ENABLE_SSH_REMOTE_PORT_FORWARDING` | `--enable-ssh-remote-port-forwarding` |
| `DISABLE_SSH_AUTH` | `--disable-ssh-auth` |
| `SSH_JWT_CACHE_TTL` | `--ssh-jwt-cache-ttl` (seconds, `0` disables caching) |

`DISABLE_SSH_AUTH=true` gives a shell to any peer that can reach the NAS. Netbird also
requires a privileged caller to *enable* SSH root login, disable SSH authentication, or
change the management URL while the SSH server is on; the service script runs as root, so
that is satisfied, but a refusal shows up in `last-error` rather than being swallowed.

### Network

| Option | `netbird up` flag | Notes |
|--------|-------------------|-------|
| `INTERFACE_NAME` | `--interface-name` | Default `wt0`. |
| `WIREGUARD_PORT` | `--wireguard-port` | Default `51820`. |
| `MTU` | `--mtu` | |
| `NETWORK_MONITOR` | `--network-monitor` | Reconnect on network changes. |
| `DISABLE_AUTO_CONNECT` | `--disable-auto-connect` | |
| `EXTRA_IFACE_BLACKLIST` | `--extra-iface-blacklist` | Comma-separated. |
| `DNS_RESOLVER_ADDRESS` | `--dns-resolver-address` | e.g. `8.8.8.8:53`. |
| `EXTRA_DNS_LABELS` | `--extra-dns-labels` | Comma-separated. |
| `DNS_ROUTER_INTERVAL` | `--dns-router-interval` | e.g. `1m`. |
| `EXTERNAL_IP_MAP` | `--external-ip-map` | Comma-separated, e.g. `1.2.3.4/eth0`. |

### Advanced

| Option | `netbird up` flag |
|--------|-------------------|
| `DISABLE_CLIENT_ROUTES` | `--disable-client-routes` |
| `DISABLE_SERVER_ROUTES` | `--disable-server-routes` |
| `DISABLE_DNS` | `--disable-dns` |
| `DISABLE_FIREWALL` | `--disable-firewall` |
| `BLOCK_LAN_ACCESS` | `--block-lan-access` |
| `BLOCK_INBOUND` | `--block-inbound` |
| `DISABLE_IPV6` | `--disable-ipv6` |
| `ENABLE_ROSENPASS` | `--enable-rosenpass` |
| `ROSENPASS_PERMISSIVE` | `--rosenpass-permissive` |
| `EXTRA_ARGS` | *(appended verbatim to `netbird up`)* |

Example configuration for a self-hosted setup with SSH access from other peers:

```
SETUP_KEY=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
MANAGEMENT_URL=https://netbird.example.com:443
HOSTNAME=my-qnap-nas
ALLOW_SERVER_SSH=true
ENABLE_SSH_ROOT=true
ENABLE_SSH_SFTP=true
LOG_LEVEL=info
```

Example configuration for Netbird's hosted service:

```
SETUP_KEY=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
HOSTNAME=qnap-home
```

## Troubleshooting

**`Management: Disconnected, reason: … 308 (Permanent Redirect); malformed header: missing
HTTP content-type`** — the peer is speaking plain-text gRPC to a server that redirects to
HTTPS. The stored management URL uses `http://`. Set `MANAGEMENT_URL` to the `https://` form
and press **Save & Restart** (the restart is what makes it take effect).

**Settings look saved but nothing changed** — they only reach Netbird on restart, and only
via `netbird down` + `netbird up`. Check `/var/log/netbird-service.log` for the
`Bringing tunnel down` line followed by `Running: netbird up …` with the flags you expect.

**The status page says connected but nothing works** — check the `Management` row rather than
the headline. The daemon status is a separate thing and reads `Connected` whenever the daemon
process is alive.

## Building locally

If you want to build the Netbird binary and QPKG yourself without the CI pipeline:

### Build the binary

```bash
# Clone the upstream Netbird source (or use a specific tag)
git clone --depth 1 --branch v0.35.1 https://github.com/netbirdio/netbird.git src

# Build a static binary for QNAP (x86_64 Linux)
cd src
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "-s -w" -o ../qpkg/x86_64/netbird ./client/

cd ..
```

The `-s -w` linker flags strip debug symbols, reducing binary size. `CGO_ENABLED=0` ensures a fully static binary with no glibc dependency.

### Package the QPKG

If you have the QNAP QDK installed:

```bash
qbuild --root qpkg
```

Without QDK, you can manually transfer the binary and service files to the NAS:

```bash
# Copy the binary
scp qpkg/x86_64/netbird admin@your-nas-ip:/etc/config/qpkg/netbird/netbird

# Copy the service script
scp qpkg/shared/netbird.sh admin@your-nas-ip:/etc/init.d/netbird.sh

# Copy the config template
scp qpkg/shared/netbird.conf admin@your-nas-ip:/etc/config/qpkg/netbird/netbird.conf

# Make executable
ssh admin@your-nas-ip "chmod +x /etc/config/qpkg/netbird/netbird /etc/init.d/netbird.sh"
```

## How upstream updates are tracked

This project does not fork or modify the Netbird source code. It simply:

1. Clones the upstream release at a specific tag
2. Cross-compiles the client binary for QNAP's platform
3. Wraps it in a QPKG with a service script and config file

When `netbirdio/netbird` publishes a new release, the scheduled CI pipeline detects the new tag, builds the updated binary, and publishes a new QPKG release. No manual intervention is needed for routine upstream updates.

To pin a specific upstream version, trigger a manual `workflow_dispatch` build with the desired version tag.

## License

The Netbird client is licensed under [BSD-3-Clause](https://github.com/netbirdio/netbird/blob/main/LICENSE). The QPKG packaging scripts and CI configuration in this repository are provided as-is.
