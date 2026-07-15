"""Connect to a BLE device by address and dump its GATT services.

Run:  python python/probe.py <address>

Confirms whether the device exposes the Mongoose-OS RPC service that
Pit Boss controllers use, and lists all characteristics.
"""

import asyncio
import sys

from bleak import BleakClient, BleakScanner
from pytboss.ble import (
    SERVICE_RPC,
    SERVICE_DEBUG,
    CHAR_RPC_DATA,
    CHAR_RPC_TX_CTL,
    CHAR_RPC_RX_CTL,
    CHAR_DEBUG_LOG,
)

KNOWN = {
    SERVICE_RPC.lower(): "Mongoose RPC service (Pit Boss control)",
    SERVICE_DEBUG.lower(): "Mongoose debug service",
    CHAR_RPC_DATA.lower(): "RPC data",
    CHAR_RPC_TX_CTL.lower(): "RPC tx ctrl",
    CHAR_RPC_RX_CTL.lower(): "RPC rx ctrl",
    CHAR_DEBUG_LOG.lower(): "debug log / live status",
}


async def main(address: str) -> None:
    print(f"Resolving {address} ...")
    device = await BleakScanner.find_device_by_address(address, timeout=15.0)
    if device is None:
        print("Could not find/resolve that device. Is it powered on and in range?")
        sys.exit(1)

    print(f"Connecting to {device.name or '(no name)'} [{address}] ...")
    async with BleakClient(device) as client:
        print(f"Connected: {client.is_connected}\n")
        has_rpc = False
        for service in client.services:
            label = KNOWN.get(service.uuid.lower(), "")
            print(f"Service {service.uuid}  {label}")
            if service.uuid.lower() == SERVICE_RPC.lower():
                has_rpc = True
            for ch in service.characteristics:
                clabel = KNOWN.get(ch.uuid.lower(), "")
                print(f"    char {ch.uuid}  {','.join(ch.properties):<28} {clabel}")
        print()
        if has_rpc:
            print("✅ CONFIRMED: this is a Pit Boss / Mongoose-OS grill controller.")
        else:
            print("❌ No Mongoose RPC service — this is probably not the grill.")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: python python/probe.py <address>")
        sys.exit(2)
    asyncio.run(main(sys.argv[1]))
