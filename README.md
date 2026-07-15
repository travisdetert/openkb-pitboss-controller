# openkb-pitboss-controller

A local **Bluetooth** controller for Pit Boss grills. No cloud, no Dansons
account, no marketing. Talks directly to the grill's Mongoose-OS controller
over BLE and gives you the controls you actually paid for.

Built and verified against a **Pit Boss Pro Series 1100 Combo**
(`PB1100PSC3`, PBL control board, firmware 0.5.7).

## Architecture

```
┌─────────────────┐   JSON over stdio   ┌──────────────────┐   BLE    ┌────────┐
│ Electron (TS)   │ ◄─────────────────► │ Python sidecar   │ ◄──────► │ Grill  │
│ main + renderer │                     │ (pytboss/bleak)  │          │  PBL   │
└─────────────────┘                     └──────────────────┘          └────────┘
```

- **Python sidecar** (`python/sidecar.py`) owns the BLE connection via
  [`pytboss`](https://github.com/dknowles2/pytboss) — proven, board-correct
  decoding. Speaks line-delimited JSON on stdin/stdout.
- **Electron main** (`src/main/`) spawns the sidecar, bridges IPC, and writes a
  unified, tailable log to `/tmp/openkb-pitboss.log`.
- **Renderer** (`src/renderer/`) is the control UI.

Why a Python sidecar instead of pure JS? `pytboss` already implements the BLE
framing and the per-control-board temperature/status decoding for 100+ models.
Reusing it is far more reliable than re-deriving byte offsets in Node.

## Setup

```bash
# Python side
python3 -m venv .venv
. .venv/bin/activate
pip install pytboss

# Electron side
npm install
npm start
```

macOS will prompt for **Bluetooth permission** for the terminal/app the first
time it scans — allow it (System Settings → Privacy & Security → Bluetooth).

## Diagnostics (no app needed)

```bash
. .venv/bin/activate
python python/scan.py            # find grills advertising the Mongoose RPC service
python python/probe.py <addr>    # dump a device's GATT services
python python/livetest.py PBL-   # connect by name, print live state (read-only)
python python/test_sidecar.py    # drive the sidecar end-to-end (read-only)
```

## Protocol notes

- The grill advertises as `PBL-<MAC>`; `PBL` is also its pytboss control board.
- **macOS rotates BLE peripheral UUIDs**, so we always match the grill by its
  stable advertised *name*, never by a cached address.
- Control flows through one MCU command (`PB.SendMCUCommand`) carrying simple
  `FE…FF` hex frames — fully local, no account.
- BLE range is short (small stock antenna); the sidecar auto-reconnects on drop.
