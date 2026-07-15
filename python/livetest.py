"""Live read test — connect to the grill via pytboss and print state.

Run:  python python/livetest.py <name-prefix> [model]

Finds the grill by BLE *name* (macOS rotates peripheral addresses, so we
match the stable advertised name), reads firmware, subscribes to live state
for a few updates, then disconnects. Read-only: sends no control commands.
"""

import asyncio
import sys

from bleak import BleakScanner
from pytboss import PitBoss, BleConnection

DEFAULT_MODEL = "PB1100PSC3"  # Pro Series 1100 Combo, PBL board


async def find_by_name(prefix: str, timeout: float = 20.0):
    """Scan for the first device whose name starts with `prefix`."""
    prefix = prefix.lower()
    found = await BleakScanner.discover(timeout=timeout, return_adv=True)
    for _addr, (device, adv) in found.items():
        name = (device.name or adv.local_name or "").lower()
        if name.startswith(prefix):
            return device
    return None


async def main(name_prefix: str, model: str) -> None:
    print(f"Scanning for a grill named '{name_prefix}*' ...")
    device = await find_by_name(name_prefix)
    if device is None:
        print("Could not find the grill by name. Is it powered on / in range?")
        sys.exit(1)
    print(f"Found {device.name} [{device.address}]")

    print(f"Connecting as model {model} ...")
    boss = PitBoss(BleConnection(device), model)

    updates = 0
    done = asyncio.Event()

    async def on_state(state):
        nonlocal updates
        updates += 1
        print(f"\n--- state update #{updates} ---")
        for k, v in state.items():
            print(f"  {k}: {v}")
        if updates >= 3:
            done.set()

    await boss.subscribe_state(on_state)
    await boss.start()
    print("Connected. Reading...\n")

    try:
        fw = await asyncio.wait_for(boss.get_firmware_version(), timeout=15)
        print(f"firmware: {fw}")
    except Exception as ex:  # noqa: BLE001
        print(f"get_firmware_version failed: {ex!r}")

    try:
        st = await asyncio.wait_for(boss.get_state(), timeout=15)
        print(f"\ninitial get_state: {st}")
    except Exception as ex:  # noqa: BLE001
        print(f"get_state failed: {ex!r}")

    try:
        await asyncio.wait_for(done.wait(), timeout=30)
    except asyncio.TimeoutError:
        print("\n(no further pushed updates within 30s — grill may be idle/off)")

    await boss.stop()
    print("\nDone. Disconnected.")


if __name__ == "__main__":
    name = sys.argv[1] if len(sys.argv) > 1 else "PBL-"
    mdl = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_MODEL
    asyncio.run(main(name, mdl))
