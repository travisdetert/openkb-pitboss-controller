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
