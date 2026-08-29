#!/usr/bin/env python3
"""Upload a NeoCNC firmware BIN over the Ender-3 Neo's CH340 serial link."""

from __future__ import annotations

import argparse
import random
import string
import sys
import time
from pathlib import Path

import serial

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "firmware/marlin/buildroot/share/scripts"))
import MarlinBinaryProtocol as mbp


def ascii_command(port: str, command: str, timeout: float = 5) -> list[str]:
    with serial.Serial(port, 115200, timeout=0.2, write_timeout=2, dsrdtr=False, rtscts=False, exclusive=True) as link:
        link.dtr = False
        link.rts = False
        time.sleep(0.2)
        link.reset_input_buffer()
        link.write((command + "\n").encode("ascii"))
        link.flush()
        lines: list[str] = []
        deadline = time.monotonic() + timeout
        quiet_until: float | None = None
        while time.monotonic() < deadline:
            raw = link.readline()
            if raw:
                line = raw.decode("utf-8", errors="replace").strip()
                if line:
                    lines.append(line)
                    quiet_until = time.monotonic() + 0.8
            elif quiet_until and time.monotonic() >= quiet_until:
                break
        return lines


def require_ok(lines: list[str], command: str) -> None:
    if "ok" not in lines or any("error" in line.lower() for line in lines):
        raise RuntimeError(f"{command} failed: {' | '.join(lines)}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("firmware", type=Path)
    parser.add_argument("--port", default="/dev/ttyUSB0")
    args = parser.parse_args()
    firmware = args.firmware.resolve()
    if not firmware.is_file() or firmware.suffix.lower() != ".bin":
        raise SystemExit("firmware must be an existing .bin file")

    m115 = ascii_command(args.port, "M115")
    if not any("Cap:BINARY_FILE_TRANSFER:1" in line for line in m115):
        raise RuntimeError("Installed firmware does not support BINARY_FILE_TRANSFER")

    m21 = ascii_command(args.port, "M21")
    if not any("SD card ok" in line for line in m21):
        raise RuntimeError(f"M21 failed: {' | '.join(m21)}")
    listed = ascii_command(args.port, "M20 F")
    old_bins = [
        line.split()[0] for line in listed
        if line.split() and line.split()[0].upper().endswith(".BIN")
    ]
    for old_bin in old_bins:
        deleted = ascii_command(args.port, f"M30 /{old_bin}")
        remaining = ascii_command(args.port, "M20 F")
        if any(line.split() and line.split()[0].upper() == old_bin.upper() for line in remaining):
            raise RuntimeError(f"M30 /{old_bin} failed: {' | '.join(deleted)}")

    target = "FW" + "".join(random.choices(string.ascii_uppercase + string.digits, k=6)) + ".BIN"
    protocol = mbp.Protocol(args.port, 115200, 512, 0, 1000)
    binary_mode = False
    try:
        protocol.connect()
        binary_mode = True
        transfer = mbp.FileTransferProtocol(protocol)
        if not transfer.copy(str(firmware), target, compression=False, dummy=False):
            raise RuntimeError("binary transfer failed")
        protocol.disconnect()
        binary_mode = False
        protocol.send_ascii("M21")
        protocol.send_ascii("M997", send_and_forget=True)
        print(f"Uploaded {target}; reboot requested.")
    finally:
        if binary_mode:
            try:
                protocol.disconnect()
            except Exception:
                pass
        protocol.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
