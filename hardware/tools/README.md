# Testing the HID board from a Mac

`board_test.py` accesses the custom BLE service without subscribing as a system HID host. Requires `uv`; the script declares its Bleak dependency. The iPhone supplies screenshots locally with ScreenCaptureKit, so this tool has no video/network commands or ffmpeg dependency.

```bash
hardware/flash.sh --debug          # optional explicit serial port
uv run hardware/tools/board_test.py info
uv run hardware/tools/board_test.py cmd ping status
uv run hardware/tools/board_test.py app status --seconds 10
uv run hardware/tools/board_test.py app 'log 30' --seconds 10
```

The encrypted status read may show a macOS pairing prompt. Do not pair the Mac as a Bluetooth mouse while the iPhone owns HID input. Only one system HID host is supported.

`cmd` forwards commands literally, including real input. For example `cmd homescreen` changes the paired iPhone's screen. Use only on a prepared test screen. The tool never retries timed-out commands automatically.

`app 'run TASK'` relays a development command to the phone, which must be foregrounded to present system screen-sharing consent. `app stop` stops a task. Shared reply notifications also carry app debug logs. Neither starting a task nor BLE pairing bypasses the phone's consent picker.

For UART use `arduino-cli monitor -p <serial port> -c baudrate=115200`, then send `1 ping` or `2 status`.
See the [protocol](../../docs/ble-protocol.md) for command and connection details.
