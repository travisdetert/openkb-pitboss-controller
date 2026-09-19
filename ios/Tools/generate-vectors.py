#!/usr/bin/env python3
"""Generate golden test vectors for PitBossKit from pytboss itself.

The Swift port must reproduce pytboss's behaviour byte-for-byte. Rather than
asserting against hand-written expectations (which would only encode my reading
of the protocol), we run pytboss's real codec/command/parse routines and dump
their output. The Swift tests assert against this file.

Run from the repo root with the project venv:
    .venv/bin/python ios/Tools/generate-vectors.py
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / ".venv/lib/python3.14/site-packages"))

from pytboss import codec, grills  # noqa: E402
from pytboss.ble import _encode_len, _decode_len  # noqa: E402


def temp_bytes(v):
    """Three decimal-digit bytes, as convertTemperature() reads them."""
    return [v // 100, (v % 100) // 10, v % 10]


NULL_TEMP = [9, 6, 0]  # convertTemperature() maps 960 -> null


def build_fe0c(p1_target, p1, p2, p3, p4, smoker, grill_set, grill, fahrenheit):
    parts = [0xFE, 0x0C]
    for v in (p1_target, p1, p2, p3, p4, smoker, grill_set, grill):
        parts += NULL_TEMP if v is None else temp_bytes(v)
    parts.append(1 if fahrenheit else 0)
    return "".join(f"{b:02X}" for b in parts)


def build_fe0b(**flags):
    parts = [0] * 44
    parts[0], parts[1] = 0xFE, 0x0B
    order = ["moduleIsOn", "err1", "err2", "err3", "highTempErr", "fanErr",
             "hotErr", "motorErr", "noPellets", "erL", "fanState", "hotState",
             "motorState", "lightState", "primeState", "isFahrenheit"]
    for i, name in enumerate(order):          # parts[24] .. parts[39]
        parts[24 + i] = 1 if flags.get(name) else 0
    parts[40] = flags.get("recipeStep", 0)
    h, m, s = flags.get("recipeTime", (0, 0, 0))
    parts[41], parts[42], parts[43] = h, m, s
    return "".join(f"{b:02X}" for b in parts)


def main():
    board = grills.get_grill("PB1100PSC3").control_board
    out = {}

    # --- Commands -------------------------------------------------------
    cmds = {}
    for slug in sorted(board.commands):
        cmd = board.commands[slug]
        if cmd._hex:
            cmds[slug] = {"args": [], "hex": cmd()}
    for slug, arg in [("set-temperature", 225), ("set-temperature", 180),
                      ("set-temperature", 500), ("set-probe-1-temperature", 145),
                      ("set-probe-1-temperature", 203)]:
        cmds[f"{slug}({arg})"] = {"args": [arg], "hex": board.commands[slug](arg)}
    out["commands"] = cmds

    # --- Temperature frames ---------------------------------------------
    temp_frames = []
    for case in [
        dict(p1_target=145, p1=132, p2=None, p3=None, p4=None,
             smoker=225, grill_set=225, grill=231, fahrenheit=True),
        dict(p1_target=203, p1=203, p2=198, p3=None, p4=None,
             smoker=250, grill_set=250, grill=248, fahrenheit=True),
        dict(p1_target=None, p1=None, p2=None, p3=None, p4=None,
             smoker=None, grill_set=180, grill=72, fahrenheit=True),
    ]:
        msg = build_fe0c(**case)
        temp_frames.append({"message": msg, "state": board.parse_temperatures(msg)})
    out["temperatureFrames"] = temp_frames

    # --- Status frames ---------------------------------------------------
    status_frames = []
    for case in [
        dict(moduleIsOn=True, fanState=True, hotState=True, motorState=True,
             isFahrenheit=True, recipeStep=2, recipeTime=(1, 30, 15)),
        dict(moduleIsOn=True, noPellets=True, fanState=True, lightState=True),
        dict(moduleIsOn=False),
        dict(moduleIsOn=True, highTempErr=True, motorErr=True, erL=True,
             primeState=True, recipeStep=0, recipeTime=(0, 0, 45)),
    ]:
        msg = build_fe0b(**case)
        status_frames.append({"message": msg, "state": board.parse_status(msg)})
    out["statusFrames"] = status_frames

    # Non-matching prefixes must parse to null.
    out["rejectedFrames"] = ["FE0A0100", "", "0000", "FE0C"[:2]]

    # --- RPC length framing ----------------------------------------------
    out["lengthFraming"] = [
        {"n": n, "bytes": list(_encode_len(n))}
        for n in (0, 1, 20, 21, 255, 256, 65535, 65536, 1_000_000)
    ]
    assert all(_decode_len(bytearray(e["bytes"])) == e["n"]
               for e in out["lengthFraming"])

    # --- Codec (grill password) ------------------------------------------
    out["timedKeys"] = [{"uptime": u, "key": codec.timed_key(u)}
                        for u in (0, 5, 5.5, 15, 100, 1234.5, 99999)]
    # encode() prepends random padding, so the stable assertion is the round
    # trip: decode(encode(x)) == x. Fixed-key decode vectors pin the maths.
    out["decodeVectors"] = []
    for plain in (b"", b"a", b"hunter2", b"0123456789abcdef"):
        enc = codec.encode(plain)
        out["decodeVectors"].append({
            "plaintextHex": plain.hex(),
            "encodedHex": enc.hex(),
            "decodedHex": codec.decode(enc).hex(),
        })

    dest = ROOT / "ios/PitBossKit/Tests/PitBossKitTests/vectors.json"
    dest.write_text(json.dumps(out, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {dest.relative_to(ROOT)}")
    print(f"  {len(out['commands'])} commands, "
          f"{len(out['temperatureFrames'])} temp frames, "
          f"{len(out['statusFrames'])} status frames, "
          f"{len(out['timedKeys'])} timed keys")


if __name__ == "__main__":
    main()
