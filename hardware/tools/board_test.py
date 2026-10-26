# /// script
# requires-python = ">=3.11"
# dependencies = ["bleak>=0.22"]
# ///
"""Inspect the HID board or relay development commands to the iPhone app.

    uv run hardware/tools/board_test.py info
    uv run hardware/tools/board_test.py cmd ping status
    uv run hardware/tools/board_test.py app status --seconds 10

`cmd` can send real mouse/keyboard input to the paired HID host. Commands are never retried.
"""
import argparse
import asyncio
import json
import time

from bleak import BleakClient, BleakScanner

BASE = "6e400001-a9e8-4b1b-9c39-6d6f8a3c"
CMD, REPLY, STATUS = (BASE + s for s in ("0001", "0002", "0003"))


class Board:
    def __init__(self, client: BleakClient):
        self.client = client
        self.next_id = 900000
        self.pending = {}
        self.write_lock = asyncio.Lock()

    async def start(self):
        await self.client.start_notify(REPLY, self.on_reply)
        await self.client.start_notify(STATUS, self.on_status)
        # Reading the encrypted characteristic triggers pairing, independently of system HID.
        print("status:", json.loads(await self.client.read_gatt_char(STATUS)))

    def on_reply(self, _, data: bytearray):
        text = data.decode(errors="replace")
        rid, _, rest = text.partition(" ")
        if rid in ("log", "app"):
            print(f"{time.strftime('%H:%M:%S')} [{rid}] {rest}", flush=True)
            return
        future = self.pending.get(rid)
        if future is not None and not future.done():
            future.set_result(rest)

    def on_status(self, _, data: bytearray):
        try:
            json.loads(data)
        except ValueError:
            print("invalid status:", data)

    async def command(self, line: str):
        self.next_id += 1
        rid = str(self.next_id)
        future = asyncio.get_running_loop().create_future()
        self.pending[rid] = future
        started = time.monotonic()
        try:
            # Bound both the GATT write and reply; an uncertain command must never be replayed.
            async with asyncio.timeout(30):
                async with self.write_lock:
                    await self.client.write_gatt_char(CMD, f"{rid} {line}".encode(), response=True)
                reply = await future
            print(f"{line} -> {reply} ({(time.monotonic() - started) * 1000:.0f} ms)", flush=True)
        finally:
            self.pending.pop(rid, None)


async def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("test", choices=["info", "cmd", "app"])
    parser.add_argument("lines", nargs="*")
    parser.add_argument("--seconds", type=float, default=10)
    parser.add_argument("--scan", type=float, default=15)
    args = parser.parse_args()
    if args.test != "info" and not args.lines:
        parser.error("provide at least one command line")
    device = await BleakScanner.find_device_by_filter(
        lambda d, ad: (d.name or ad.local_name or "").startswith("ESP32 Agent"), timeout=args.scan)
    if device is None:
        raise SystemExit("Board not found; check power and advertising.")
    print("found", device.name, device.address)
    async with BleakClient(device, timeout=20) as client:
        board = Board(client)
        await board.start()
        for line in args.lines if args.test != "info" else []:
            await board.command("app " + line if args.test == "app" else line)
        if args.test == "app":
            await asyncio.sleep(max(0, args.seconds))


if __name__ == "__main__":
    asyncio.run(main())
