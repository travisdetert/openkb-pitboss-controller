"""BLE scan tool — finds Pit Boss / Mongoose-OS grills nearby.

Run:  python python/scan.py [seconds]

Lists every advertising BLE device, flags any that expose the Mongoose-OS
RPC service used by Pit Boss controllers. Use this to confirm your grill
speaks BLE and to grab its address for the sidecar.
"""

import asyncio
import sys

from bleak import BleakScanner
from pytboss.ble import SERVICE_RPC

RPC = SERVICE_RPC.lower()


async def main(duration: float) -> None:
    print(f"Scanning {duration:.0f}s for BLE devices "
          f"(Pit Boss RPC service = {RPC})...\n")

    # return_adv gives us advertised service UUIDs so we can flag grills.
    found = await BleakScanner.discover(timeout=duration, return_adv=True)

    grills = []
    others = []
    for address, (device, adv) in found.items():
        uuids = [u.lower() for u in (adv.service_uuids or [])]
        is_grill = RPC in uuids
        row = {
            "name": device.name or adv.local_name or "(no name)",
            "address": address,
            "rssi": adv.rssi,
            "uuids": uuids,
        }
        (grills if is_grill else others).append(row)

    if grills:
        print("=== PIT BOSS GRILLS FOUND ===")
        for g in grills:
            print(f"  ✅ {g['name']}  [{g['address']}]  rssi={g['rssi']}dBm")
        print()
    else:
        print("No device advertised the Pit Boss RPC service.")
        print("(The grill may need to be powered on, in range, and not")
        print(" already connected to the official app.)\n")

    print(f"=== ALL OTHER DEVICES ({len(others)}) ===")
    for d in sorted(others, key=lambda x: x["rssi"], reverse=True):
        print(f"  {d['name']:<28} [{d['address']}]  rssi={d['rssi']}dBm"
              + (f"  uuids={d['uuids']}" if d["uuids"] else ""))


if __name__ == "__main__":
    secs = float(sys.argv[1]) if len(sys.argv) > 1 else 12.0
    try:
        asyncio.run(main(secs))
    except Exception as ex:  # noqa: BLE001
        print(f"\nScan failed: {ex!r}")
        print("\nOn macOS, the app running Python (Terminal/iTerm) needs "
              "Bluetooth permission:\n  System Settings → Privacy & Security "
              "→ Bluetooth → enable your terminal.")
        sys.exit(1)
