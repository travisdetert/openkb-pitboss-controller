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
notable tradeoffs as an ADR. **No security pass has been run yet — one is due
before the first push.**
