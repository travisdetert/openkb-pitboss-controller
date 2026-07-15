"""Drive the sidecar over a subprocess pipe and print its events.

Read-only smoke test: connect -> observe state -> refresh -> disconnect.
Sends no commands that change the grill.
"""

import asyncio
import json
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))


async def main():
    proc = await asyncio.create_subprocess_exec(
        sys.executable, os.path.join(HERE, "sidecar.py"),
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=None,  # let stderr pass through to our terminal
    )

    async def send(obj):
        proc.stdin.write((json.dumps(obj) + "\n").encode())
        await proc.stdin.drain()
        print(f">>> {obj}")

    async def reader():
        states = 0
        async for raw in proc.stdout:
            try:
                evt = json.loads(raw.decode())
            except Exception:
                print("non-json:", raw)
                continue
            t = evt.get("type")
            if t == "state":
                states += 1
                d = evt["data"]
                print(f"<<< state #{states}: grill={d.get('grillTemp')}/"
                      f"{d.get('grillSetTemp')}F  p1={d.get('p1Temp')} "
                      f"p2={d.get('p2Temp')}  light={d.get('lightState')}")
            else:
                print(f"<<< {evt}")

    rtask = asyncio.create_task(reader())

    await asyncio.sleep(1)
    await send({"id": 1, "cmd": "connect", "name": "PBL-", "model": "PB1100PSC3"})
    await asyncio.sleep(25)
    await send({"id": 2, "cmd": "refresh"})
    await asyncio.sleep(5)
    await send({"id": 3, "cmd": "disconnect"})
    await asyncio.sleep(3)

    proc.stdin.close()
    try:
        await asyncio.wait_for(proc.wait(), timeout=5)
    except asyncio.TimeoutError:
        proc.terminate()
    rtask.cancel()


if __name__ == "__main__":
    asyncio.run(main())
