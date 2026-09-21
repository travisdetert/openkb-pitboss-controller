# Security Posture — openkb-pitboss-controller

Local-first desktop app: an Electron front end driving a Python BLE sidecar that
talks to a Pit Boss grill. No cloud service, no accounts, no remote API.

## Sensitive data / secrets
- **None.** No credentials, API keys, or tokens. The grill speaks unauthenticated
  local BLE. Persisted data is non-sensitive: settings (`userData/settings.json`)
  and cook history JSONL (temperatures/timestamps) under the app's userData dir.

## External / untrusted inputs
- **BLE peripheral data** decoded by `pytboss` in the sidecar — treat grill
  advertisements and state frames as untrusted; never `eval`/format them into
  shell or markup. Match grills by stable advertised *name* (macOS rotates UUIDs).
- **Sidecar ↔ main IPC**: line-delimited JSON over stdio. Parse defensively;
  reject malformed lines rather than trusting shape.
- **Renderer → main IPC**: validate/bound command args (e.g. setpoint within the
  board's min/max, probe index in range) before forwarding to the sidecar.
- **settings.json / cook JSONL**: parsed at startup — tolerate corrupt/partial
  files (store already merges over defaults).

## Network / IPC / process-exec / filesystem surfaces
- **Process exec:** main spawns the venv Python + `python/sidecar.py`. Paths come
  from the project root or `PITBOSS_PYTHON` / `PITBOSS_SIDECAR` env overrides — do
  not let untrusted input set these; pass args as an argv array (no shell string).
- **BLE:** the only "network". Local radio only; no inbound listeners.
- **Electron hardening:** `contextIsolation: true`, `nodeIntegration: false`,
  preload-exposed API only — keep it that way; do not enable remote content.
- **Filesystem:** writes confined to `app.getPath('userData')` and the unified log
  at `/tmp/openkb-pitboss.log`. Keep cook/log filenames derived from sanitized
  timestamps (already filename-safe), never from raw device strings.
- **macOS permissions:** declare `NSBluetoothAlwaysUsageDescription` (and Bonjour
  strings if mDNS is added) in the packaged Info.plist so the OS prompts instead
  of silently denying; handle the denied state gracefully.

## Security-pass procedure
Run before the first push and whenever touching IPC, process-exec, the BLE/
protocol layer, filesystem paths, or dependencies:
- `/security-review` skill on the pending diff/branch.
- `gitleaks dir --no-banner .` — secret scan.
- `osv-scanner scan source --recursive .` — dependency CVEs (npm + pip); also
  `npm audit` and check `pytboss`/`bleak`.
- `semgrep --config auto` scoped to `src/` and `python/`.

Fix High/Critical before pushing; note Medium/Low in the PR/commit body and record
notable tradeoffs as an ADR.

## Security-pass record

### 2026-07-19 — first-push pass (clean, with tracked follow-ups)
Run before the first push to GitHub (`travisdetert/openkb-pitboss-controller`, public).

- **gitleaks** (`dir` + `git`): **no leaks in tracked history** (14 commits). The
  4 `dir`-mode hits were RSA public keys inside Electron's own
  `resources.pak`, under the gitignored `release/` build output — not tracked,
  not secrets.
- **npm audit** (`--omit=dev`): **0 vulnerabilities**.
- **osv-scanner**: initially **18 findings, all `electron` (dev), CVSS ≤ 8.1** —
  Chromium/Electron CVEs against the then-pinned `electron@33.4.11`. This app
  loads only local bundled HTML with `contextIsolation` on, `nodeIntegration`
  off, and no remote content, so the web-content attack surface these mostly
  require is not present. **Resolved 2026-07-20:** bumped Electron to **43.1.1**
  (latest stable; Electron only security-patches the newest three majors, so 43
  maximizes support runway). Re-scan reports **no issues**; app re-verified —
  builds, tests pass, boots and connects on 43 with no renderer errors.
- **semgrep** (`--config auto`, `src/` + `python/`): **3 `path-join` traversal
  heuristics in `recorder.ts`**, all reviewed:
  - `readCook(id)` (IPC-reachable) — **fixed:** `id` is now validated against the
    fixed cook-id timestamp shape (`isValidCookId`) before any path is built.
  - `startCook` — id is an internally generated `fileStem()` timestamp. Safe.
  - `metaFor(filename)` — `filename` comes from `fs.readdirSync(this.dir)`, so it
    is already a real entry in the dir. Safe.
  The latter two remain flagged (the linter can't see the guards) — accepted.

Result: clean — no High/Critical open, and the one tracked follow-up (Electron
refresh) was completed the next day (2026-07-20, Electron 43.1.1).

### 2026-07-21 — session manager (delete/rename) pass
The session manager adds two IPC-reachable, filesystem-mutating operations, so it
gets its own pass.

- **New surface:** `Recorder.deleteCook(id)` (`fs.unlinkSync`) and
  `renameCook(id, name)`, both reachable from the renderer via IPC. Both **validate
  `id` with `isValidCookId` before building any path**, so a traversal id
  (`../../etc/passwd`) is rejected before touching disk — verified against a
  throwaway temp dir (traversal → rejected; the active/recording cook → refused;
  rename of a missing file → refused). Cook names are stored in the settings map
  (`cookNames`), trimmed and length-capped (60), not written into file paths.
- **semgrep**: now **5 `path-join` heuristics in `recorder.ts`** — the 3 above plus
  the two new `deleteCook` / `renameCook` paths. All reviewed and safe: internally
  generated (`fileStem`), `readdir`-sourced, or `isValidCookId`-guarded. Flagged
  because the linter can't see the guard; **accepted**.
- **gitleaks** (`git` + `docs/`): no leaks; the new `docs/screenshots/dashboard.png`
  contains no tokens or secrets. **npm audit / osv-scanner:** unchanged since
  Electron 43 — still clean.

Result: clean — no High/Critical open. The delete path is guarded and the
destructive operation confirmed refusing traversal ids and the active cook.

### 2026-09-18 — native iOS app (ADR 0006)
The iOS port (`ios/`) adds a second implementation of the BLE protocol, so it
gets its own pass. Scanners run from the repo root.

- **New surface:**
  - `BLETransport` (CoreBluetooth) — speaks only to a BLE peripheral whose
    advertised name the user picked from a scan. No sockets, no HTTP, no
    listener. The app makes **no network connections at all**; pytboss's cloud
    login (`auth.py`, `wss.py`) was deliberately not ported.
  - `ControlBoard` — **executes JavaScript from `grills.json` via
    JavaScriptCore.** This is the one genuinely widened surface and is
    **accepted**, because: the file is *vendored into the app bundle at build
    time*, never fetched at runtime; it is byte-identical to the file the
    desktop app already executes through pytboss/dukpy; and a bare `JSContext`
    is a sealed interpreter — no filesystem, no network, no host objects are
    exposed to it. The only values crossing in are an integer temperature and a
    hex frame string; the only value crossing out is parsed as a string or a
    numeric dictionary. A malicious `grills.json` would mean a compromised
    build, at which point the JS is the least of the problem.
  - `Codec` — the grill-password obfuscation. **Not cryptography and documented
    as such** in the source; it exists because the firmware expects it. The
    password lives only in memory on the controller, defaults to empty (which
    skips the path entirely), and is never written to disk or into the log.
- **Input handling:** every frame from the grill is untrusted. `DebugFrame.parse`
  requires the exact three-part shape *and* a matching length before the payload
  is used; the board routines reject any frame without their `FE0B`/`FE0C`
  prefix and return null rather than throwing. RPC replies are matched by `id`
  and dropped if unparseable. Malformed input is discarded, never guessed at.
- **Logging:** `PitBossLog` records connection events and command names, not
  payloads or the password. It is capped at 512 KB with rotation so a long cook
  can't fill the device.
- **No third-party dependencies.** `PitBossKit` links only system frameworks
  (Foundation, CoreBluetooth, JavaScriptCore, os). There is no new supply chain.
- **semgrep** (295 rules, 23 files incl. untracked): **0 findings**.
- **gitleaks** (full tree, 137 MB): **no leaks**.
- **osv-scanner**: no new findings attributable to iOS. Pre-existing and
  **unrelated to this change**, still open in the desktop sidecar's
  `requirements.txt`: `aiohttp` 3.14.1 (PYSEC-2026-3545 / 7.1, plus two more)
  and `idna` 3.9.0 (PYSEC-2026-215 / 6.9). Both are pulled in by pytboss for its
  *cloud* transport, which neither app uses; worth bumping regardless. The npm
  findings remain dev-only (electron-builder's transitive tree).

Result: clean for the new code — no High/Critical introduced. One accepted
tradeoff (JavaScriptCore execution of vendored `grills.json`), one pre-existing
item flagged for follow-up (`aiohttp` / `idna` bumps).

### 2026-09-18 — iOS cook persistence
Recording cooks to disk adds the first filesystem **write** surface in the iOS
app, and a read path driven by an identifier, so it gets a note.

- **New surface:** `CookStore` writes `<Application Support>/cooks/<id>.jsonl`
  and reads it back for the history screen. The app sandbox already confines
  this to the app's own container.
- **Path traversal:** a cook id becomes a filename, and `readCook`/`deleteCook`/
  `renameCook` are reachable from the UI, so **every id is validated against
  `^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}$` before any path is built** — the same
  guard, for the same reason, as the desktop recorder (see the 2026-07-21 entry).
  Verified in `pitboss-verify`: `../../etc/passwd`, `..`, `""`, a colon-bearing
  ISO timestamp and an embedded `/../` are each rejected by all three entry
  points, not merely by the regex.
- **Destructive operations:** deletion refuses the cook currently being written,
  and is only reachable through an explicit swipe-to-delete. Renaming stores the
  label in `UserDefaults` rather than rewriting the recorded file, so a rename
  can never corrupt or truncate data.
- **Contents:** a cook file holds timestamps, temperatures and component
  booleans. No credentials, no location, no account data — there is no account.
  The grill password (when set) is never written to disk or into a cook file.
- **Format:** byte-compatible with the desktop recorder's JSONL, checked by
  parsing a Swift-written file with the desktop's own `readCook` logic
  (`npm run ios:interop`).
- **semgrep** (32 files): **0 findings**. **gitleaks**: no leaks.

Result: clean — no High/Critical introduced. The traversal guard is the load-
bearing control and is covered by checks rather than by inspection alone.

### 2026-09-18 — iOS notifications & background execution
Two additions worth a note, neither of which widens the data surface.

- **Local notifications** (`UserNotifications`): composed and delivered entirely
  on-device. No push service, no token, no server — nothing leaves the phone.
  Permission is requested at first connect and a denial degrades to in-app
  banners only. Bodies carry temperatures and probe names; no credentials.
- **`UIBackgroundModes: bluetooth-central`**: lets the app keep its BLE link
  while backgrounded, which is what makes an unattended cool-down and an alert
  on the lock screen possible. It grants no additional data access — the app
  still talks only to the peripheral the user picked, and still makes no network
  connections of any kind.
- **semgrep** (50 files): 0 findings. **gitleaks**: no leaks.

Result: clean — no High/Critical introduced.

### 2026-09-20 — pre-push pass over the whole unpushed branch
The branch carried six commits and roughly two months of work — the native iOS
app, the shared cooking knowledge base, the desktop cooking UI, and the BLE
reconnect rework — none of it pushed. This pass covers all of it, with the
reconnect work (transport code) as the reason it was owed.

**Scanners.**
- **gitleaks** (155 MB scanned): no leaks.
- **osv-scanner**: 45 known vulnerabilities across 11 packages in 2 ecosystems
  → **0**. See the dependency note below.
- **npm audit**: 6 vulnerabilities (5 High, 1 Critical) → **0**.
- **semgrep** (`--config auto`, scoped to `src/ scripts/ python/ ios/`): 6
  findings, **all false positives** — analysed below.

**semgrep's 6 path-traversal findings, and why none is real.** Every hit is
`path.join(this.dir, …)` in `src/main/recorder.ts`. Four of them (`readCook`,
the new `readCookEvents`, `deleteCook`, `renameCook`) are preceded on the
immediately prior line by `isValidCookId(id)`, and `COOK_ID_RE` is
`/^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}$/` — fully anchored, digits and dashes
only, so neither `.` nor `/` can appear in a value that passes. The fifth
(`startCook`) uses the recorder's own generated `cookId`, never an argument.
The sixth (`metaFor`) takes filenames from `readdirSync` of the cooks directory
itself. Recorded here rather than suppressed, so the next pass does not have to
re-derive it.

**Code review of the branch diff.** No findings at or above the reporting bar.
What was specifically traced and cleared:
- The **cook-id guard is applied consistently** on every path that builds a
  filename from an id, including the newly added `readCookEvents`. iOS mirrors
  it (`CookStore.isValidID`, funnelled through a single `url(for:)`).
- **The two new IPC handlers take no arguments.** `pitboss:cooking` reads a
  fixed `__dirname`-relative path; `pitboss:cooks:events` uses the recorder's
  internal `cookId`. No renderer-supplied value reaches a filesystem path.
- **No XSS.** Every `innerHTML` site in the renderer interpolates either an
  `esc()`-wrapped string, a coerced number, or an internal class literal. All
  attributes in template literals are double-quoted (checked), so `esc()` not
  escaping `'` is not reachable. User-supplied cook names and probe labels
  reach only `textContent` and `input.value`. A cook event's `note` is never
  rendered. The CSP in `index.html` (`default-src 'self'`) blocks inline
  handlers and remote script regardless.
- **BLE payloads cannot inject JavaScript.** The per-model routines run on
  JavaScriptCore, but the frame is passed as a **call argument**
  (`fn.call(withArguments:)`), never concatenated into script source. The
  `JSContext` has no host objects and no bridged Swift objects.
- **No network surface on iOS at all** — no `URLSession`, no `WKWebView`, no
  ATS exceptions. Nothing to bypass.
- **The grill password is never logged** — only a slug and a hex command.
- `scripts/stop.mjs` matches only command lines containing this project's
  absolute root *and* `electron`, and uses `execFileSync` with argv arrays, so
  there is no shell string to inject into.

**Dependencies.** `aiohttp` 3.14.1 → 3.14.3 (PYSEC-2026-3545/3546/3547). `idna`
was never pinned, so a fresh checkout could resolve to a vulnerable 3.9.0
(PYSEC-2026-215) even though this machine's venv had floated to 3.18; it now
carries a `>=3.15` floor. The 41 npm findings were all dev-only — the
electron-builder toolchain (`tar`, `undici`, `@xmldom/xmldom`,
`brace-expansion`, `fast-uri`, `js-yaml`) — and none ship inside the packaged
app, but `npm audit fix` cleared them without touching a runtime dependency.
Re-verified after the bump: sidecar imports resolve, the frozen binary rebuilds
and runs with no external Python references, `npm test` green, `ios:interop`
green.

The new `requirements-dev.txt` (build-time only) initially declared
`Pillow>=11.0`, and the rescan that caught it is the reason this note exists: a
floor is what the scanner resolves, so `>=11.0` meant 11.0, which carries seven
findings up to 8.7. The floor is now `>=12.3.0`. Regenerating every icon on
12.3.0 produces byte-identical output, so the bump costs nothing.

Result: **clean** — no High/Critical introduced, and every previously tracked
dependency finding is closed.

### 2026-09-20 — Bluetooth permission UX
One new IPC channel, `pitboss:bluetooth:settings`. It takes **no arguments** and
opens a single hardcoded URL
(`x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth`)
via `shell.openExternal`, guarded on `process.platform === 'darwin'`. Nothing
renderer-supplied reaches it, so it cannot be steered at another scheme or
target — the usual `openExternal` risk.

The new `PITBOSS_BT_BLOCKED` affordance is dev-only and, like the existing
replay and screenshot flags, is an environment variable: trusted input, and
validated against a fixed list regardless. It only ever *degrades* what the app
believes it can do — it cannot fabricate a working connection.

The blocked reason is rendered through `textContent`, not `innerHTML`, and the
message it carries originates in bleak, not in a device.

Result: clean — no new externally-reachable surface.
