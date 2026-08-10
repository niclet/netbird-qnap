# CHANGELOG

Complete history of the netbird-qnap project, documenting every commit, what was
tried, what worked, what failed, and the current state.

---

## Commit-by-Commit History (oldest first)

### 1. `197b27c` -- QNAP Netbird, when this builds

**Date:** 2026-03-26

The initial commit. Created the entire project skeleton from scratch:

- **`.github/workflows/build.yml`**: CI pipeline with three jobs:
  - `check-version`: queries the latest netbird release tag from GitHub, compares
    against existing releases, skips build if already released (unless forced).
  - `build`: clones upstream netbird source, detects Go version from `go.mod`,
    cross-compiles a static `CGO_ENABLED=0 GOOS=linux GOARCH=amd64` binary,
    generates icons with ImageMagick, builds the QPKG using QDK's `qbuild`.
  - `release`: downloads the built artifact and creates a GitHub release with
    checksums.
- **`qpkg/qpkg.cfg`**: QPKG metadata -- name `netbird`, display name
  `Netbird VPN`, version `0.0.0` (updated by CI), service program `netbird.sh`,
  PID file at `/var/run/netbird.pid`, minimum QTS 4.3.0. No web UI settings at
  this point.
- **`qpkg/shared/netbird.sh`**: Service script handling start/stop/restart/status.
  Sources `netbird.conf` to get `SETUP_KEY`, `MANAGEMENT_URL`, etc. Starts the
  daemon with `netbird service run`, waits for `/var/run/netbird.sock`, then runs
  `netbird up` if a setup key is configured.
- **`qpkg/shared/netbird.conf`**: User-editable config template with commented
  options for `SETUP_KEY`, `MANAGEMENT_URL`, `ADMIN_URL`, `HOSTNAME`, `LOG_LEVEL`,
  `LOG_FILE`, `EXTRA_ARGS`.
- **`qpkg/package_routines`**: Install/remove hooks -- chmod binaries, preserve
  user config across upgrades, create `/etc/netbird`, clean up symlinks on remove.
- **`README.md`**: Extensive documentation covering architecture, why Docker does
  not work on QNAP (read-only `/proc/sys`, no iptables in containers), installation
  instructions, configuration reference, local build guide.
- **`.gitignore`**: Ignores `src/`, compiled binaries, `*.qpkg`, build output, and
  generated icons.

**Web UI settings:** None. No `QPKG_WEBUI`, no web interface at all.

---

### 2. `b0aac9d` -- dirs

**Date:** 2026-03-26

**Problem:** The CI build failed because `qpkg/x86_64/` and `qpkg/icons/` directories
did not exist on the CI runner (they were gitignored and empty).

**Fix:**
- Added `mkdir -p qpkg/x86_64` before the Go build step.
- Added `mkdir -p qpkg/icons` before the icon generation step.
- Added `.gitkeep` files in `qpkg/icons/` and `qpkg/x86_64/` so the directories
  exist in the repo.

---

### 3. `be63fe6` -- dirs

**Date:** 2026-03-26

**Problem:** QDK build tooling was not being found correctly. Also updated action
versions.

**Changes:**
- Updated `actions/checkout` from v4 to v6, `actions/setup-go` from v5 to v6,
  `actions/upload-artifact` from v4 to v5, `actions/download-artifact` from v4 to v5.
- Changed QDK build approach: instead of using `qbuild` from `/tmp/qdk/bin/`, now
  builds QDK from source (`make -C /tmp/qdk/src`), copies `qpkg_encrypt` to
  `/usr/local/bin/`, and uses `/tmp/qdk/shared/bin/qbuild`.
- Removed `fakeroot` and `pv` from apt dependencies (kept `rsync` and `bsdmainutils`).

---

### 4. `bb08a6a` -- fix: QDK build setup for CI

**Date:** 2026-03-26

**Problem:** The QDK setup was still fragile and inline in the workflow.

**Fix:** Extracted all QDK setup into a standalone `build-qpkg.sh` script:
- Clones QDK to `/tmp/qdk`, symlinks `shared` into `qpkg/QDK`.
- Builds `qpkg_encrypt` from source if not available.
- Installs `rsync` and `hexdump` if missing.
- Runs `qbuild --root .` from the `qpkg/` directory.
- Added `qpkg/QDK` to `.gitignore`.

The workflow now just calls `./build-qpkg.sh`.

---

### 5. `41c532a` -- add QNAP app repository for auto-updates via App Center

**Date:** 2026-03-26

**What:** Added a QNAP App Center repository so users can get automatic updates
instead of manually downloading `.qpkg` files.

**Changes:**
- Created `repo.xml` with QNAP plugin metadata: name, description, icons,
  firmware version requirement, and platform entries for `TS-NASX86`, `TS-X28A`,
  `TS-X41`, `TS-X73`. Download URLs pointed to
  `https://github.com/ZachHandley/netbird-qnap/releases/latest/download/netbird.qpkg`
  (this URL format turned out to be wrong -- the filename is versioned, not just
  `netbird.qpkg`).
- Updated the workflow's release job to:
  - Add `pages: write` and `id-token: write` permissions.
  - Update `repo.xml` with the new version number and a cache-busting timestamp.
  - Deploy `repo.xml` to GitHub Pages by creating a temporary git repo on the
    `gh-pages` branch and force-pushing it.
- Updated release notes to include the App Center repository URL.
- Updated `README.md` with "Option A: Add the app repository" instructions.

---

### 6. `7d789f9` -- use actions/deploy-pages for repo.xml

**Date:** 2026-03-26

**Problem:** The manual git-push-to-gh-pages approach for deploying `repo.xml` was
clunky and required manual git operations in CI.

**Fix:** Replaced the manual `git init`/`git push --force` approach with the
official GitHub Pages actions:
- `actions/upload-pages-artifact@v4` to upload the `_pages/` directory.
- `actions/deploy-pages@v4` to deploy to GitHub Pages.
- Added the `github-pages` environment with URL output.

---

### 7. `cecdaed` -- add web UI settings page for QNAP App Center

**Date:** 2026-03-26

**What:** First attempt at a web-based settings UI for configuring Netbird from the
QNAP App Center "Open" button.

**Web UI approach #1: QTS web root symlink**

**Changes:**
- Added `QPKG_WEBUI="/netbird/"` to `qpkg.cfg`. This tells QTS that clicking "Open"
  in the App Center should navigate to `/netbird/` on the QTS management server.
- In `netbird.sh` start, added:
  `ln -sf "${QPKG_ROOT}/web" /home/Qhttpd/Web/netbird`
  This symlinks the web directory into QTS's built-in web server root so it serves
  the files at `/netbird/`.
- Created `qpkg/shared/web/index.html`: A single-page settings UI with fields for
  Setup Key, Management URL, Admin URL, Hostname, Log Level, Log File, Extra Args.
  Shows connection status, has Save and Save & Restart buttons. Calls a CGI API at
  `/netbird/cgi-bin/netbird-api.cgi`.
- Created `qpkg/shared/web/cgi-bin/netbird-api.cgi`: A shell-based CGI script that
  handles `load` (read config), `save` (write config), `status` (run
  `netbird status`), and `restart` (call `netbird.sh restart`). Uses a simple JSON
  parser with `sed`.
- Updated `package_routines` to chmod the CGI script on install and clean up the
  symlink on remove.

**Problem with this approach:** The QTS built-in web server (thttpd/Qhttpd) may not
execute CGI scripts from symlinked directories, and the `/netbird/` path relies on
the QTS web root being writable and the server being configured to serve from
symlinked subdirectories.

---

### 8. `f4f4765` -- fix repo.xml download URL, add concurrency limit

**Date:** 2026-03-26

**Changes:**
- Added `concurrency: group: build-qpkg, cancel-in-progress: true` to the workflow
  to prevent parallel builds from conflicting.
- Fixed a problem where re-releasing the same version would fail: now deletes any
  existing release before creating a new one
  (`gh release delete "$VERSION" --yes --cleanup-tag`).
- Changed `repo.xml` download URLs from hardcoded
  `https://github.com/.../releases/latest/download/netbird.qpkg` to a
  `__QPKG_URL__` placeholder that gets replaced at build time with the actual
  release asset URL (fetched via `gh release view ... --json assets`).

**Problem:** The `__QPKG_URL__` approach required querying the release API after
creating the release, which added complexity. This was changed again in the next
commit.

---

### 9. `f49f39e` -- fix web UI: use busybox httpd on port 8090, stable download URL

**Date:** 2026-03-26

**Web UI approach #2: busybox httpd on custom port**

The QTS web root symlink approach was abandoned. This commit switched to running a
dedicated web server.

**Changes to qpkg.cfg:**
- Changed `QPKG_WEBUI` from `"/netbird/"` to `"/"`.
- Added `QPKG_WEB_PORT="8090"`.
- The combination of `QPKG_WEBUI="/"` and `QPKG_WEB_PORT="8090"` tells QTS that
  clicking "Open" in App Center should open `http://<nas-ip>:8090/`.

**Changes to netbird.sh:**
- Replaced the symlink approach (`ln -sf ... /home/Qhttpd/Web/netbird`) with
  starting busybox's built-in HTTP server:
  `busybox httpd -p 8090 -h "${QPKG_ROOT}/web" -c "${QPKG_ROOT}/web/httpd.conf"`
- On stop, kills the httpd process: `kill $(pidof "busybox httpd")`

**Added `httpd.conf`:** A busybox httpd config file with:
```
A:*
/cgi-bin:admin
*.cgi:CGI
```

**Removed** the `/home/Qhttpd/Web/netbird` symlink cleanup from `package_routines`
(no longer used).

**Download URL fix:** Abandoned the `__QPKG_URL__` placeholder approach. Instead:
- Creates a stable-named copy of the QPKG as `netbird_x86_64.qpkg` alongside the
  versioned one.
- Changed `repo.xml` URLs to
  `https://github.com/ZachHandley/netbird-qnap/releases/latest/download/netbird_x86_64.qpkg`
  which always points to the latest release.

---

### 10. `f604743` -- fix artifact upload path

**Date:** 2026-03-26

**Problem:** The artifact upload step was listing individual files with complex path
expressions, which was fragile.

**Fix:** Simplified the upload path to just `qpkg/build/` to upload the entire build
output directory.

---

### 11. `82d584d` -- fix: remove invalid httpd.conf, busybox httpd needs no config

**Date:** 2026-03-26

**Problem:** The `httpd.conf` file created in commit `f49f39e` was likely causing
busybox httpd to fail. The QNAP busybox httpd may not support the config file
format used, or the CGI directives were not working.

**Fix:**
- Removed `qpkg/shared/web/httpd.conf` entirely.
- Changed the httpd start command from
  `busybox httpd -p 8090 -h "${QPKG_ROOT}/web" -c "${QPKG_ROOT}/web/httpd.conf"`
  to just `busybox httpd -p 8090 -h "${QPKG_ROOT}/web"` (no config file).

**Implication:** Without the config file, busybox httpd would serve static files but
would NOT execute CGI scripts. This means the settings page HTML would load, but
the API calls to `/cgi-bin/netbird-api.cgi` would fail (the CGI script would be
served as a download or return an error instead of being executed). The web UI was
effectively broken at this point -- it could display the form but could not load,
save, or query status.

---

### 12. `311e2d2` -- auto-increment packaging version suffix on forced rebuilds

**Date:** 2026-03-27

**What:** Improved the version numbering for forced rebuilds so they do not collide
with previous releases.

**Changes:**
- Added a `release_tag` output to the `check-version` job.
- When no prior release exists for a version, uses the version as-is (e.g., `v0.67.1`).
- When a prior release exists and force is true:
  - If the prior release is the bare version (`v0.67.1`), the new tag becomes
    `v0.67.1-2`.
  - If the prior release already has a suffix (`v0.67.1-2`), increments to
    `v0.67.1-3`.
- The QPKG version converts dashes to dots for QNAP compatibility
  (e.g., `v0.67.1-2` becomes `0.67.1.2`).
- The `release_tag` is used for the GitHub release tag and the repo.xml version.

---

### 13. `f1254bb` -- embed settings UI inline in QTS desktop

**Date:** 2026-03-27

**Web UI approach #2.5: busybox httpd + desktop app mode**

An attempt to make the web UI appear as an inline window inside the QTS desktop
instead of opening a new browser tab.

**Changes to qpkg.cfg:**
- Kept `QPKG_WEBUI="/"` and `QPKG_WEB_PORT="8090"` (still using busybox httpd).
- Added `QPKG_DESKTOP_APP="1"` -- tells QTS to open the web UI inside an iframe
  in the QTS desktop rather than in a new browser tab.
- Added `QPKG_USE_PROXY="1"` -- tells QTS to proxy requests through the QTS
  management port so the custom port (8090) does not need to be exposed directly.

**Problem:** This approach still relied on busybox httpd (without a config file, so
no CGI support). The `QPKG_USE_PROXY="1"` setting tells QTS to proxy requests to
port 8090, which means the page would load in the desktop, but the CGI API would
still not work because busybox httpd was not configured to execute CGI scripts.

---

### 14. `7fc8e8d` -- fix web UI: use QTS management server, inline desktop app

**Date:** 2026-03-27

**Web UI approach #3: QTS management server with symlinks (return to approach #1, enhanced)**

Abandoned the busybox httpd approach entirely and returned to using the QTS
built-in web server, but with a more complete setup.

**Changes to qpkg.cfg:**
- Removed `QPKG_WEB_PORT="8090"` (no more custom port).
- Changed `QPKG_WEBUI` from `"/"` back to `"/netbird/"`.
- Kept `QPKG_USE_PROXY="1"`.
- Added `QPKG_DESKTOP_APP="1"`.
- Added `QPKG_DESKTOP_APP_WIN_WIDTH="700"` and `QPKG_DESKTOP_APP_WIN_HEIGHT="500"`.

**Changes to netbird.sh:**
- Removed busybox httpd start (`busybox httpd -p 8090 ...`).
- Replaced with two symlinks:
  - `ln -sf "${QPKG_ROOT}/web" /home/Qhttpd/Web/netbird` -- serves static files at
    `/netbird/`.
  - `ln -sf "${QPKG_ROOT}/web/cgi-bin/netbird-api.cgi" /home/httpd/cgi-bin/netbird-api.cgi`
    -- places the CGI script in QTS's CGI directory where the management server
    (thttpd) can execute it.
- On stop, removes both symlinks.
- On remove (in `package_routines`), also cleans up both symlinks.

**Changes to index.html:**
- Changed the API endpoint from `'/netbird/cgi-bin/netbird-api.cgi'` to
  `'/cgi-bin/netbird-api.cgi'` because the CGI script is now symlinked into the
  system CGI directory, not served from within the `/netbird/` web root.

**Key insight:** QTS has two separate web server components:
1. `/home/Qhttpd/Web/` -- the static file root served by QTS's thttpd/Qhttpd
   (serves HTML, CSS, JS).
2. `/home/httpd/cgi-bin/` -- the CGI directory where QTS's thttpd can execute
   scripts.

By symlinking the web directory and the CGI script separately into these two
locations, both static file serving and CGI execution should work through the QTS
management port (typically 8080 or 443).

---

### 15. `af5f3ad` -- [release] build on commit with [release] tag, fix web UI symlinks

**Date:** 2026-03-27

**Changes:**
- Modified the build trigger logic: now builds if the commit message contains
  `[release]` (case-insensitive), in addition to the existing triggers (first
  build, forced, new upstream version). This allows triggering a release build by
  including `[release]` in the commit message.
- Simplified the version suffix logic: always computes the release tag (even when
  not building), then decides whether to build based on the trigger conditions.

This commit had `[release]` in its message, so it triggered a CI build to test the
web UI changes from the previous commit.

---

### 16. `643699c` -- [release] remove QPKG_USE_PROXY, serve directly via QTS thttpd

**Date:** 2026-03-28

**Web UI approach #3.5: QTS management server, no proxy**

**Changes to qpkg.cfg:**
- Removed `QPKG_USE_PROXY="1"`.
- Kept `QPKG_WEBUI="/netbird/"`.
- Kept `QPKG_DESKTOP_APP="1"` with window dimensions.
- Updated comment to clarify: "Web UI served through QTS management server via
  symlink into /home/Qhttpd/Web/."

**Rationale:** The `QPKG_USE_PROXY` setting may have been causing issues. Without
it, QTS should serve `/netbird/` directly from the web root symlink rather than
trying to proxy requests to a backend port.

**Problem:** Without `QPKG_USE_PROXY`, QTS may need the proxy setting to properly
route requests to the web content when `QPKG_DESKTOP_APP` is enabled. The desktop
app iframe may need the proxy mechanism to display content correctly.

---

### 17. `a99c5e9` -- [release] fix web UI: proxy through QTS management port, no custom server (HEAD)

**Date:** 2026-03-28

**Web UI approach #4 (current): QTS management server with proxy, desktop app**

**Changes to qpkg.cfg:**
- Re-added `QPKG_USE_PROXY="1"` (was removed in the previous commit).
- Kept everything else the same.

**Rationale:** The proxy setting was needed after all. `QPKG_USE_PROXY="1"` tells
QTS to proxy the web UI path through the management port, which is necessary for
the desktop app iframe to work properly. Without it, the previous commit's approach
apparently did not work.

---

### 18. (uncommitted) -- fix web UI: add logging, clean stale config, match QNAP official pattern

**Date:** 2026-03-29

**Web UI approach #5: match QNAP official pattern exactly + add logging + clean stale config**

**Research findings:** Searched GitHub for every working QPKG with a web UI. Found
that QNAP's own official examples (QDK-Guide breakout, helloWorld) and community
packages (ZeroTier, Storj, USBRun, RoonServer) ALL use the same pattern:

```
QPKG_WEBUI="/name/"
QPKG_USE_PROXY="1"
QPKG_DESKTOP_APP="1"
# NO QPKG_WEB_PORT
```

With a symlink: `ln -s $QPKG_ROOT/web /home/Qhttpd/Web/<name>`

Source: https://github.com/qnap-dev/QDK-Guide (breakout.sh, QNAP_HelloWorld.sh)

This is the SAME pattern we had at commit `a99c5e9`. The config was correct. The 503
was likely caused by stale `Web_Port` entries in `/etc/config/qpkg.conf` from previous
installs that used `QPKG_WEB_PORT="8090"`. QTS persists package settings and old
values can poison the proxy routing.

The busybox httpd approach (attempted earlier in this uncommitted change) was wrong --
the Perplexity research was misleading. `QPKG_USE_PROXY="1"` with symlinks (no
`QPKG_WEB_PORT`) IS the correct pattern per QNAP's own examples.

**Changes to qpkg.cfg:**
- Removed `QPKG_WEB_PORT="58090"` (was added incorrectly).
- Config now matches QNAP official examples exactly.

**Changes to netbird.sh:**
- Added comprehensive logging to `/var/log/netbird-service.log`:
  - Logs every startup step with timestamps
  - Verifies symlinks were created successfully
  - Verifies web files exist at the expected paths
  - Dumps qpkg.conf entries (Enable, Web_Port, WebUI, Proxy_Path, Use_Proxy)
- Reverted to symlink-based web UI (matching official examples).
- Added stale config cleanup: clears `Web_Port` from qpkg.conf on start.
- Kills leftover busybox httpd from previous versions.
- Fixed `log_tool -t2` to `log_tool -t1` (type 2 = error notifications in QNAP,
  type 1 = informational).

**Changes to index.html:**
- Reverted API URL to `'/cgi-bin/netbird-api.cgi'` (absolute path, since CGI is
  symlinked to QTS's cgi-bin directory, not served under /netbird/).

**Changes to package_routines:**
- Added stale Web_Port cleanup and busybox httpd kill to `pkg_post_install`.
- Reverted `PKG_POST_REMOVE` to clean up symlinks.
- Fixed `log_tool -t2` to `log_tool -t1` in all hooks.

**Request flow:**
```
User clicks "Open" in QTS App Center
  -> QTS desktop opens iframe to /netbird/ (QPKG_DESKTOP_APP="1")
  -> QTS Apache serves from /home/Qhttpd/Web/netbird (symlink to $QPKG_ROOT/web)
  -> index.html loads
  -> JS calls /cgi-bin/netbird-api.cgi (symlink to $QPKG_ROOT/web/cgi-bin/netbird-api.cgi)
```

**If still 503 after this change:** check `/var/log/netbird-service.log` for the
exact qpkg.conf state and symlink status. The log will show exactly what went wrong.

---

## Web UI / Settings Panel Saga -- Summary

| # | Commit | Approach | QPKG_WEBUI | WEB_PORT | USE_PROXY | DESKTOP_APP | Served By | Result |
|---|--------|----------|------------|----------|-----------|-------------|-----------|--------|
| 1 | `cecdaed` | QTS web root symlink | `/netbird/` | -- | -- | -- | QTS Apache via symlink | Unknown -- no proxy, no desktop app |
| 2 | `f49f39e` | busybox httpd + httpd.conf | `/` | `8090` | -- | -- | busybox httpd | httpd.conf format probably invalid |
| 3 | `82d584d` | busybox httpd, no config | `/` | `8090` | -- | -- | busybox httpd | HTML loads, CGI unknown |
| 4 | `f1254bb` | busybox + desktop + proxy | `/` | `8090` | `1` | `1` | busybox proxied by QTS | Unknown -- not tested long enough |
| 5 | `7fc8e8d` | QTS server + dual symlinks | `/netbird/` | -- | `1` | `1` | QTS Apache via symlinks | 503 -- possibly stale Web_Port from #4 |
| 6 | `643699c` | QTS server, no proxy | `/netbird/` | -- | -- | `1` | QTS Apache via symlinks | 503 -- possibly stale Web_Port from #4 |
| 7 | `a99c5e9` | QTS server + proxy | `/netbird/` | -- | `1` | `1` | QTS Apache via symlinks | 503 -- possibly stale Web_Port from #4 |
| 8 | (this) | Official pattern + logging | `/netbird/` | -- | `1` | `1` | QTS Apache via symlinks | Matches QNAP official examples; cleans stale config; has logging |

**Key lessons learned:**
- `QPKG_USE_PROXY="1"` + symlinks + NO `QPKG_WEB_PORT` IS the official QNAP
  pattern. Every QNAP example (breakout, helloWorld) and community QPKG
  (ZeroTier, Storj, USBRun) uses this exact combination.
- Stale `Web_Port` entries in `/etc/config/qpkg.conf` from previous installs can
  poison the proxy routing, causing 503 even with correct qpkg.cfg.
- `log_tool -t2` creates ERROR notifications in QNAP. Use `-t1` for informational.
- Always add logging. Flying blind across 7 iterations wasted time.

---

## Current State (as of this uncommitted change)

### Architecture

**Core VPN service:**
- Statically-linked Netbird client binary for x86_64.
- Service script (`netbird.sh`) starts daemon, waits for gRPC socket, brings tunnel up.
- Configuration in `netbird.conf` (shell variables).

**Web UI (matching QNAP official pattern):**
- `qpkg.cfg`: `QPKG_WEBUI="/netbird/"`, `QPKG_USE_PROXY="1"`,
  `QPKG_DESKTOP_APP="1"` (700x500). NO `QPKG_WEB_PORT`.
- On start: creates symlinks:
  - `${QPKG_ROOT}/web` -> `/home/Qhttpd/Web/netbird` (static files)
  - `${QPKG_ROOT}/web/cgi-bin/netbird-api.cgi` -> `/home/httpd/cgi-bin/netbird-api.cgi` (CGI)
- Cleans stale `Web_Port` from qpkg.conf and kills leftover busybox httpd.
- `index.html`: single-page settings form, calls `/cgi-bin/netbird-api.cgi` (absolute).
- `netbird-api.cgi`: shell CGI script for load/save/status/restart.
- On stop/remove: removes symlinks.

**Logging:**
- Service log: `/var/log/netbird-service.log` (startup steps, symlink verification,
  qpkg.conf state, errors).
- Netbird log: `/var/log/netbird.log` (daemon and VPN logs).
- QNAP notifications: use `log_tool -t1` (informational, not error).

**CI/CD:**
- Triggers: push to main, daily cron, manual dispatch, `[release]` in commit message.
- Auto-increments version suffix on forced rebuilds.
- Deploys `repo.xml` to GitHub Pages for QNAP App Center auto-updates.
- Stable download URL: `netbird_x86_64.qpkg` in latest release.

### Files

```
.github/workflows/build.yml              -- CI pipeline
build-qpkg.sh                            -- QDK setup and qbuild wrapper
repo.xml                                 -- QNAP App Center repository manifest
CHANGELOG.md                             -- This file
qpkg/qpkg.cfg                            -- QPKG metadata and web UI settings
qpkg/package_routines                    -- Install/remove hooks
qpkg/shared/netbird.sh                   -- Service start/stop/restart script
qpkg/shared/netbird.conf                 -- Config file template
qpkg/shared/web/index.html              -- Settings UI (single-page HTML/JS)
qpkg/shared/web/cgi-bin/netbird-api.cgi  -- CGI API for settings UI
```

---

## Settings never reached Netbird; full `netbird up` options added

**Date:** 2026-08-09
**Upstream verified against:** netbird `v0.76.2`

### Symptom

`netbird status` on the NAS:

```
Connected

OS: linux/amd64
Daemon version: 0.76.2
Management: Disconnected, reason: failed getting Management Service public key:
  rpc error: code = Unknown desc = unexpected HTTP status code received from
  server: 308 (Permanent Redirect); malformed header: missing HTTP content-type
```

Setting a correct `https://` management URL on the settings page changed nothing,
and the package still reported a successful start.

### Root cause

Four defects stacked on top of each other.

1. **`netbird up` discards config when the daemon is already connected.**
   `client/cmd/up.go:305`:

   ```go
   if status.Status == string(internal.StatusConnected) {
       if !profileSwitched {
           cmd.Println("Already connected")
           return nil          // returns BEFORE client.SetConfig(ctx, req)
       }
   ```

   `SetConfig` — which carries `ManagementUrl` and every SSH flag — is below that
   return. `StatusConnected` is the *daemon* status, which reads Connected even
   while Management is down.

2. **`start_service` raced the daemon's auto-connect.** It started the daemon,
   waited for the socket, then ran bare `netbird up`. The daemon auto-connects
   from its stored profile on start (`DisableAutoConnect` defaults false), so
   `up` almost always hit the early return above. Settings were passed via `NB_*`
   environment variables, which do reach the flags
   (`SetFlagsFromEnvVars`, `client/cmd/root.go:236`) but are discarded by the same
   early return.

3. **Failure was invisible.** `netbird up`'s exit code was ignored, the script
   logged `=== START COMPLETE ===` unconditionally, and the script ended in a
   hardcoded `exit 0` — so QTS saw success even when the tunnel never came up.
   The settings page decided its badge with `status.includes('Connected')`, which
   matches the daemon-status line, so it was green throughout.

4. **The 308 itself** came from the Caddy edge in front of the self-hosted
   management server: a plain-HTTP gRPC POST returns `308 Permanent Redirect`
   with no `Content-Type`, which is verbatim what grpc-go reports. The peer's
   stored profile held a `http://` URL and nothing could overwrite it because of
   (1)–(3).

Two more defects found while tracing:

- **Upgrades wiped the config.** `netbird.conf` shipped in `qpkg/shared/`, so QDK
  extracted it over the install directory on every upgrade, resetting `SETUP_KEY`
  and `MANAGEMENT_URL`. The `netbird.conf.default` guard in `package_routines` ran
  *after* extraction and referenced a file nothing ever produced — dead code.
- **`HOSTNAME` leaked from the environment.** `netbird.conf` was sourced straight
  into the service script, and QTS always has `HOSTNAME` set, so the NAS hostname
  was passed as `NB_HOSTNAME` even with the setting blank.

### Changes

**New `qpkg/shared/netbird-common.sh`** — one option table (`NB_OPTION_TABLE`)
shared by the service script and the CGI, plus config load/write, shell quoting,
boolean normalisation, URL validation and JSON escaping.

**`qpkg/shared/netbird.sh`**
- Runs `netbird down` before `netbird up`, always. This is the actual fix.
- Builds an explicit argv from the config file instead of relying on `NB_*`
  environment variables, so the config file — not the stored profile — is
  authoritative. Setup key and pre-shared key are redacted from the log.
- Booleans are tri-state: only `true`/`false` emit a flag. Empty emits nothing,
  because netbird treats an unset `ServerSSHAllowed` as *enabled* and blindly
  sending `--allow-server-ssh=false` would disable SSH on existing peers.
- Checks `netbird up`'s exit code, records the output to `${QPKG_ROOT}/last-error`,
  and no longer logs `START COMPLETE` on failure.
- `exit $?` instead of `exit 0`.
- Runs `netbird up` under `timeout` (syntax probed at runtime — BusyBox changed
  from `timeout -t SEC` to `timeout SEC`) so an unexpected interactive SSO flow
  cannot hang the QPKG start. `QPKG_TIMEOUT` start raised 60s → 150s to match.
- Skips `up` entirely when there is no setup key *and* the peer is unregistered,
  which is the only case where `up` would block on SSO.
- Config values are read into namespaced `NBQ_*` variables via a subshell that
  unsets every key first, killing the `HOSTNAME` leak.

**`qpkg/config/netbird.conf`** (moved from `qpkg/shared/`) + `qpkg/qpkg.cfg`
- Declared `QPKG_CONFIG="netbird.conf"` / `QDK_DATA_DIR_CONFIG="config"`, so QDK
  md5-tracks the file and upgrades preserve user edits.
- `package_routines` restores `netbird.conf.qdkorig` / `.qdksave` on the first
  upgrade that adopts `QPKG_CONFIG`, which is when QDK sets the old file aside.
  The dead `.default` branch is gone.
- Template documents all 34 options, including that empty ≠ false for booleans.
- Default management URL corrected to `https://api.netbird.io:443`;
  `api.wiretrustee.com` has been serving an expired `*.netbird.io` certificate
  since 2026-04-27.

**`qpkg/shared/web/cgi-bin/netbird-api.cgi`**
- `do_status` returns `netbird status --json` verbatim plus the detail text and
  `last-error`, instead of substring-matching the human-readable output.
- `do_save` iterates the shared option table, so new options need no CGI change.
  Validates URLs (scheme required), integers and booleans; warns — without
  blocking — on a plain `http://` management URL, naming the 308 it causes.
- Values are written single-quoted, so a `"`, `` ` `` or `$` in a field can no
  longer corrupt the config or inject into the service script.
- A request carrying only some fields updates only those fields.
- JSON string extraction moved from sed to awk: the regex that steps over escaped
  quotes needs BRE alternation (`\|`), a GNU extension that BSD sed rejects.

**`qpkg/shared/web/index.html`**
- Status panel reads the JSON. The badge comes from `management.connected`, and
  `management.error` is shown verbatim — the 308 is now on screen.
  Also surfaces signal, relays, peers, FQDN, NetBird IP and SSH-server state.
- Form is generated from a schema mirroring `NB_OPTION_TABLE`: Connection, SSH
  server, Network, Logging, Advanced. Booleans render as *Leave unchanged / On /
  Off*. Each field shows the `netbird up` flag it maps to.
- New options: `--allow-server-ssh`, `--enable-ssh-root`, `--enable-ssh-sftp`,
  `--enable-ssh-local-port-forwarding`, `--enable-ssh-remote-port-forwarding`,
  `--disable-ssh-auth`, `--ssh-jwt-cache-ttl`, `--interface-name`,
  `--wireguard-port`, `--mtu`, `--network-monitor`, `--disable-auto-connect`,
  `--extra-iface-blacklist`, `--dns-resolver-address`, `--extra-dns-labels`,
  `--dns-router-interval`, `--external-ip-map`, `--preshared-key`,
  `--disable-client-routes`, `--disable-server-routes`, `--disable-dns`,
  `--disable-firewall`, `--block-lan-access`, `--block-inbound`, `--disable-ipv6`,
  `--enable-rosenpass`, `--rosenpass-permissive`.

### Verification

- All 31 emitted flags grepped against `client/cmd/{root,up,ssh,system}.go` at
  netbird `v0.76.2`.
- The UI schema, the shell option table and the config template were
  cross-checked: 34 keys each, no strays, boolean typing agrees.
- Shell behaviour tested under `dash`: config round-trip, `HOSTNAME` non-leak,
  argv construction, secret redaction, and that a `$(...)` in a config value is
  stored and passed verbatim rather than executed.
- Service script exercised end to end against a stubbed netbird: `down` precedes
  `up`; a failed `up` returns non-zero, records `last-error`, and does not log
  `START COMPLETE`; an unregistered peer with no setup key skips `up`.
- CGI exercised end to end: validation rejects a scheme-less URL without writing,
  `http://` saves with the 308 warning, partial saves preserve other fields, and
  the status response stays valid JSON with quotes, backslashes and newlines in it.

### Files

```
.github/workflows/build.yml              -- CI pipeline
build-qpkg.sh                            -- QDK setup and qbuild wrapper
repo.xml                                 -- QNAP App Center repository manifest
CHANGELOG.md                             -- This file
qpkg/qpkg.cfg                            -- QPKG metadata, web UI, QPKG_CONFIG
qpkg/package_routines                    -- Install/remove hooks
qpkg/config/netbird.conf                 -- Config template (upgrade-preserved)
qpkg/shared/netbird-common.sh            -- Shared option table and helpers
qpkg/shared/netbird.sh                   -- Service start/stop/restart script
qpkg/shared/web/index.html               -- Settings UI (single-page HTML/JS)
qpkg/shared/web/cgi-bin/netbird-api.cgi  -- CGI API for the settings UI
```
