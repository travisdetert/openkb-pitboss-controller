"""Pit Boss control sidecar.

A long-running process that owns the BLE connection to the grill (via
pytboss) and bridges it to the Electron app over a simple line-delimited
JSON protocol:

  stdin   <- commands   (one JSON object per line)
  stdout  -> events     (one JSON object per line)
  stderr  -> human logs  (never parsed)

Keeping the BLE/protocol logic here means we reuse pytboss's battle-tested,
board-correct decoding instead of re-implementing it. Local Bluetooth only;
no cloud, no account.

--- Commands (stdin) ---
  {"id":1, "cmd":"scan", "seconds":8}
  {"id":2, "cmd":"connect", "name":"PBL-", "model":"PB1100PSC3"}
  {"id":3, "cmd":"set_temp", "value":225}
  {"id":4, "cmd":"set_probe", "probe":1, "value":145}
  {"id":5, "cmd":"light", "on":true}
  {"id":6, "cmd":"prime", "on":true}
  {"id":7, "cmd":"off"}
  {"id":8, "cmd":"refresh"}          # force a get_state
  {"id":9, "cmd":"disconnect"}
  {"cmd":"ping"}

--- Events (stdout) ---
  {"type":"ready"}
  {"type":"scan_result","id":1,"devices":[{"name":...,"rssi":...}]}
  {"type":"status","connected":bool,"connecting":bool,"reason":str}
  {"type":"capabilities","model":...,"min_temp":...,"max_temp":...,
                          "meat_probes":...,"has_lights":...}
  {"type":"state","data":{...}}
  {"type":"ack","id":N,"ok":true,"result":...}
  {"type":"error","id":N,"message":...}        # id omitted if unsolicited
"""

from __future__ import annotations

import asyncio
import json
import sys
import threading
import traceback
from typing import Any

from bleak import BleakScanner
from pytboss import PitBoss, BleConnection
from pytboss.grills import get_grill, get_grills


# ----------------------------------------------------------------------------
# stdout / stderr helpers
# ----------------------------------------------------------------------------

def emit(obj: dict[str, Any]) -> None:
    """Write one JSON event to stdout (the channel the app parses)."""
    sys.stdout.write(json.dumps(obj, default=str) + "\n")
    sys.stdout.flush()


def log(*args: Any) -> None:
    """Human-readable diagnostics to stderr (tee'd into the app log file)."""
    print("[sidecar]", *args, file=sys.stderr, flush=True)


# ----------------------------------------------------------------------------
# Controller
# ----------------------------------------------------------------------------

class GrillController:
    """Owns the connection lifecycle and command dispatch for one grill."""

    def __init__(self, loop: asyncio.AbstractEventLoop) -> None:
        self.loop = loop
        self.boss: PitBoss | None = None
        self.conn: BleConnection | None = None
        self.name_prefix = "PBL-"
        self.model = "PB1100PSC3"
        self.connected = False
        self.want_connected = False      # user intent, drives auto-reconnect
        self._reconnect_task: asyncio.Task | None = None
        self._last_state: dict[str, Any] = {}

    # --- discovery -----------------------------------------------------------

    async def _find_device(self, prefix: str, timeout: float):
        """Find the grill by advertised name. macOS rotates BLE addresses,
        so the stable identifier is the name (it embeds the MAC)."""
        prefix_l = prefix.lower()
        found = await BleakScanner.discover(timeout=timeout, return_adv=True)
        best = None
        for _addr, (device, adv) in found.items():
            name = (device.name or adv.local_name or "")
            if name.lower().startswith(prefix_l):
                # prefer the strongest signal if several match
                if best is None or adv.rssi > best[1]:
                    best = (device, adv.rssi)
        return best[0] if best else None

    async def scan(self, seconds: float):
        found = await BleakScanner.discover(timeout=seconds, return_adv=True)
        devices = []
        for _addr, (device, adv) in found.items():
            name = device.name or adv.local_name or ""
            if name.upper().startswith(("PBL", "PBV", "PB")):
                devices.append({"name": name, "rssi": adv.rssi})
        devices.sort(key=lambda d: d["rssi"], reverse=True)
        return devices

    # --- connection ----------------------------------------------------------

    async def connect(self, name: str | None, model: str | None):
        if name:
            self.name_prefix = name
        if model:
            self.model = model
        self.want_connected = True

        # One immediate attempt for fast feedback when the grill is in range.
        # On failure we DON'T raise — a grill controller should just keep
        # trying in the background until it's reachable (status drives the UI).
        ok = await self._attempt_connect()
        if not ok:
            self._ensure_reconnect_loop()
        return ok

    async def _attempt_connect(self) -> bool:
        """One discovery+connect attempt. Emits status; never raises."""
        emit({"type": "status", "connected": False, "connecting": True,
              "reason": "scanning"})
        try:
            device = await self._find_device(self.name_prefix, timeout=15.0)
        except Exception as ex:  # noqa: BLE001
            log("scan failed:", repr(ex))
            device = None
        if device is None:
            emit({"type": "status", "connected": False, "connecting": False,
                  "reason": "not_found"})
            return False

        try:
            log(f"connecting to {device.name} as {self.model}")
            self.conn = BleConnection(device, disconnect_callback=self._on_disconnect)
            self.boss = PitBoss(self.conn, self.model)
            await self.boss.subscribe_state(self._on_state)
            await self.boss.start()
            self.connected = True
        except Exception as ex:  # noqa: BLE001
            log("connect attempt failed:", repr(ex))
            self.connected = False
            emit({"type": "status", "connected": False, "connecting": False,
                  "reason": "connect_failed"})
            return False

        # Tell the UI what this model can do so it can configure itself.
        self._emit_capabilities()
        emit({"type": "status", "connected": True, "connecting": False,
              "reason": "connected", "device": device.name})

        # Prime an initial state read.
        try:
            st = await asyncio.wait_for(self.boss.get_state(), timeout=15)
            self._on_state(st)
        except Exception as ex:  # noqa: BLE001
            log("initial get_state failed:", repr(ex))
        return True

    def _ensure_reconnect_loop(self):
        if self.want_connected and (self._reconnect_task is None
                                    or self._reconnect_task.done()):
            self._reconnect_task = self.loop.create_task(self._reconnect_loop())

    def _emit_capabilities(self):
        try:
            g = get_grill(self.model)
            emit({"type": "capabilities", "model": self.model,
                  "min_temp": g.min_temp, "max_temp": g.max_temp,
                  "temp_increments": list(g.temp_increments or []),
                  "meat_probes": g.meat_probes, "has_lights": g.has_lights})
        except Exception as ex:  # noqa: BLE001
            log("capabilities lookup failed:", repr(ex))

    def _on_state(self, state: dict[str, Any]):
        # Merge — pushed FE0B and FE0C frames carry different field subsets.
        self._last_state.update({k: v for k, v in state.items() if v is not None})
        emit({"type": "state", "data": self._last_state})

    def _on_disconnect(self, _client):
        log("BLE disconnected")
        self.connected = False
        emit({"type": "status", "connected": False, "connecting": False,
              "reason": "disconnected"})
        self._ensure_reconnect_loop()

    async def _reconnect_loop(self):
        delay = 3
        while self.want_connected and not self.connected:
            log(f"retrying connection in {delay}s...")
            await asyncio.sleep(delay)
            if not self.want_connected:
                return
            if await self._attempt_connect():
                return
            delay = min(delay * 2, 30)

    async def disconnect(self):
        self.want_connected = False
        if self.boss is not None:
            try:
                await self.boss.stop()
            except Exception as ex:  # noqa: BLE001
                log("stop failed:", repr(ex))
        self.connected = False
        self.boss = None
        self.conn = None
        emit({"type": "status", "connected": False, "connecting": False,
              "reason": "disconnected"})

    # --- guarded command helpers --------------------------------------------

    def _require(self) -> PitBoss:
        if self.boss is None or not self.connected:
            raise RuntimeError("not connected")
        return self.boss

    async def set_temp(self, value: int):
        return await self._require().set_grill_temperature(int(value))

    async def set_probe(self, probe: int, value: int):
        boss = self._require()
        if probe == 1:
            return await boss.set_probe_temperature(int(value))
        if probe == 2:
            return await boss.set_probe_2_temperature(int(value))
        raise ValueError(f"unsupported probe {probe}")

    async def light(self, on: bool):
        boss = self._require()
        return await (boss.turn_light_on() if on else boss.turn_light_off())

    async def prime(self, on: bool):
        boss = self._require()
        return await (boss.turn_primer_motor_on() if on
                      else boss.turn_primer_motor_off())

    async def off(self):
        return await self._require().turn_grill_off()

    async def refresh(self):
        st = await self._require().get_state()
        self._on_state(st)
        return self._last_state


# ----------------------------------------------------------------------------
# Model registry (for the first-run picker)
# ----------------------------------------------------------------------------

def _list_models(control_board: str | None) -> list[dict]:
    """Supported grill models, pre-filtered to a control board when given.

    The command protocol is defined per control board, so a name-prefix match
    (PBL-… -> PBL) narrows the picker to the handful of relevant models; if the
    board is unknown or has no matches, fall back to the full list.
    """
    grills = []
    if control_board:
        try:
            grills = list(get_grills(control_board=control_board))
        except Exception as ex:  # noqa: BLE001
            log("get_grills(control_board) failed:", repr(ex))
    if not grills:
        grills = list(get_grills())

    out = []
    for g in grills:
        cb = getattr(g.control_board, "name", None)
        out.append({
            "name": g.name,
            "control_board": cb,
            "min_temp": g.min_temp,
            "max_temp": g.max_temp,
            "meat_probes": g.meat_probes,
            "has_lights": g.has_lights,
        })
    out.sort(key=lambda m: m["name"])
    return out


# ----------------------------------------------------------------------------
# Command dispatch
# ----------------------------------------------------------------------------

async def handle(ctrl: GrillController, msg: dict[str, Any]) -> None:
    cmd = msg.get("cmd")
    mid = msg.get("id")
    # Log mutating commands so the unified log shows exactly what we sent the
    # grill (success path included) — "did my click do anything?" answered.
    if cmd not in (None, "ping", "refresh", "scan"):
        log("cmd:", json.dumps({k: v for k, v in msg.items() if k != "id"}))
    try:
        if cmd == "ping":
            result = "pong"
        elif cmd == "scan":
            result = await ctrl.scan(float(msg.get("seconds", 8)))
            emit({"type": "scan_result", "id": mid, "devices": result})
            return
        elif cmd == "list_models":
            # Supported grill models for the first-run picker. The BLE name prefix
            # maps to a control board (PBL-… -> PBL); pre-filter to that board's
            # models when we can, else return the full list.
            board = msg.get("control_board")
            models = _list_models(board)
            emit({"type": "models", "id": mid, "control_board": board, "models": models})
            return
        elif cmd == "connect":
            await ctrl.connect(msg.get("name"), msg.get("model"))
            result = "connected"
        elif cmd == "disconnect":
            await ctrl.disconnect()
            result = "disconnected"
        elif cmd == "set_temp":
            result = await ctrl.set_temp(msg["value"])
        elif cmd == "set_probe":
            result = await ctrl.set_probe(int(msg.get("probe", 1)), msg["value"])
        elif cmd == "light":
            result = await ctrl.light(bool(msg.get("on")))
        elif cmd == "prime":
            result = await ctrl.prime(bool(msg.get("on")))
        elif cmd == "off":
            result = await ctrl.off()
        elif cmd == "refresh":
            result = await ctrl.refresh()
        else:
            raise ValueError(f"unknown command: {cmd!r}")
        emit({"type": "ack", "id": mid, "ok": True, "result": result})
    except Exception as ex:  # noqa: BLE001
        log("command failed:", cmd, repr(ex))
        log(traceback.format_exc())
        emit({"type": "error", "id": mid, "ok": False, "message": str(ex)})


# ----------------------------------------------------------------------------
# stdin reader (runs in a thread, feeds an asyncio queue)
# ----------------------------------------------------------------------------

def _stdin_reader(loop: asyncio.AbstractEventLoop,
                  queue: asyncio.Queue) -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError as ex:
            log("bad json on stdin:", repr(ex))
            continue
        asyncio.run_coroutine_threadsafe(queue.put(obj), loop)
    # stdin closed -> parent went away -> shut down.
    asyncio.run_coroutine_threadsafe(queue.put(None), loop)


async def main() -> None:
    loop = asyncio.get_running_loop()
    queue: asyncio.Queue = asyncio.Queue()
    ctrl = GrillController(loop)

    threading.Thread(target=_stdin_reader, args=(loop, queue),
                     daemon=True).start()

    emit({"type": "ready", "model_default": ctrl.model,
          "name_default": ctrl.name_prefix})

    while True:
        msg = await queue.get()
        if msg is None:
            break
        # Each command runs as its own task so a slow BLE op doesn't block
        # reading further commands (e.g. an OFF while a scan is in flight).
        loop.create_task(handle(ctrl, msg))

    log("stdin closed; shutting down")
    await ctrl.disconnect()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
