# 5. Package the Python sidecar as a frozen binary

Date: 2026-07-23

## Status

Accepted

## Context

The app's BLE logic lives in a Python sidecar (`python/sidecar.py`, using
`bleak` + `pytboss`). For distribution the sidecar has to travel *inside* the
`.app` — an installed app has no system Python or project `.venv` to fall back on.

The first packaging attempt bundled the dev `.venv` as an extra resource
(`.venv → pyenv`) and pointed the app at `pyenv/bin/python python/sidecar.py`. The
`ship-check` packaged-build verification proved this is a **dead end**: a venv is
*not relocatable*. Inside the built `.app`:

```
pyenv/bin/python3.14 -> /opt/homebrew/opt/python@3.14/bin/python3.14   ← symlink OUT of the .app
pyvenv.cfg:  home = /opt/homebrew/opt/python@3.14/bin                   ← absolute dev-machine path
```

It ran on the dev machine only because it borrowed the dev's Homebrew Python
through that symlink. On a clean machine (no Homebrew, no `python@3.14`) the
symlink dangles, the sidecar can't spawn, and the app can't reach the grill. This
blocked the "runs from a clean machine" Definition-of-Done item.

Python is an interpreter, not a compiler, so there is no native "ship one file"
path — the interpreter, stdlib, and C-extension deps (`bleak` pulls `pyobjc` /
CoreBluetooth) all have to travel together and be relocatable.

## Decision

**Freeze the sidecar into a self-contained binary with PyInstaller** and bundle
that instead of the venv.

- `npm run build:sidecar` (`scripts/build-sidecar.mjs`) runs PyInstaller
  `--onefile` over `python/sidecar.py`, collecting `bleak` + `pytboss`, producing
  `dist-sidecar/sidecar` — a single binary with the Python runtime and all deps
  inside it.
- `npm run pack` runs it before `electron-builder`; `build.extraResources` bundles
  `dist-sidecar/sidecar → Resources/sidecar` (the `.venv`/`python` bundle is gone).
- When packaged, main spawns the binary **directly** via `PITBOSS_SIDECAR_BIN`
  (no `python` invocation); `sidecar.ts` falls back to the venv + `sidecar.py` in
  dev, so the dev workflow is unchanged.
- PyInstaller is a **build-time** tool (installed into the venv on demand by the
  build script), not a runtime or committed dependency.

## Consequences

- **The packaged app is self-contained** — no system Python, no relocatable-venv
  problem. Verified: the frozen binary boots (`bleak`+`pytboss` import inside it)
  and answers the sidecar protocol with no interpreter present.
- **Smaller bundle** — drops the ~73 MB venv, adds a ~12 MB binary.
- **Per-target build** — the binary is arch/OS-specific (built for macOS arm64
  here). Cross-platform packaging (Windows/Linux) freezes the sidecar on each
  target, in that platform's CI.
- **Dev is untouched** — `npm start` still runs the venv + `sidecar.py`; only
  `npm run pack` needs the freeze.
- Sits alongside the graceful-shutdown and discovery ADRs as a packaging decision;
  the general lesson (a language interpreter can't produce a sealed artifact — a
  compiled/frozen binary can) is why a sidecar boundary was the right architecture.
