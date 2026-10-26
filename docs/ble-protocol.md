# BLE protocol (ESP32 ⇄ iOS app)

The board is a BLE peripheral named `ESP32 Agent XXXX` (last two Bluetooth MAC bytes).
It executes HID input. ScreenCaptureKit captures the screen on the iPhone; no images or network credentials travel over BLE.
Security uses LE Secure Connections, bonding and Just Works. Reading encrypted `status` triggers pairing.

Service: `6e400001-a9e8-4b1b-9c39-6d6f8a3c0000`.

| Characteristic | UUID suffix | Properties | Purpose |
|---|---|---|---|
| cmd | 0001 | encrypted write, write without response | UTF-8 `<id> <command>` |
| reply | 0002 | notify | `<id> ok [result]` or `<id> err <reason>` |
| status | 0003 | encrypted read, notify | JSON status, once per second; full value available by read |

Replace the final four digits of the service UUID with the suffix above. The former video and network characteristics have been removed.

## Commands

`id` is a decimal request ID; the response echoes it. Supported commands:

- `ping`, `status` — connectivity and current status.
- `home` — rehome the relative mouse pointer; distinct from the system Home Screen.
- `homescreen` — Consumer AC Home (`0x0223`), returning to the Home Screen.
- `move DX DY`, `press`, `release`, `click`, `scroll V H` — relative mouse input.
- `type TEXT`, `key COMBO` — US-layout ASCII typing and keyboard shortcuts (for example `cmd+h`).
- `app COMMAND`, `log TEXT` — development relay between the Mac and app; not capture transport.
- `unpair` — erase bonds and restart advertising.

UART accepts the same `<id> <command>` format. An acknowledged command means reports were handed to the Bluetooth stack, not that the screen reached the intended state. The agent verifies the resulting screenshot. Timed-out input is not blindly replayed.

## Status

```json
{"up":123456,"rst":"power-on","heap":81234,"hid":"ok","hgen":1,"ble":{"mtu":515,"phy":1,"rdrop":0,"n":1}}
```

`up` is milliseconds since boot; `rst` is `power-on|brownout|watchdog|crash|software|usb|other`.
`ble.rdrop` counts dropped replies and `ble.n` counts connected centrals. Notify payloads must fit MTU−3; the app also reads status periodically.

`hid` is independent of the custom app connection: `ok` requires an encrypted, unsuspended host subscribed to all three input reports in report mode; `asleep` means HID suspend; `off` means not ready. `hgen` changes on relevant input/command connection, subscription, suspend and protocol transitions so the app can invalidate pointer position.

## System HID service

The same peripheral advertises standard service `0x1812`. iOS owns it; the app uses the custom service above. Pair in Settings → Accessibility → Touch → AssistiveTouch → Devices → Bluetooth Devices.

| Report ID | Input payload | Purpose |
|---|---|---|
| 1 | buttons, X, Y, wheel, pan (5 bytes) | Relative mouse, signed 8-bit deltas |
| 2 | modifiers, reserved, six key usages (8 bytes) | ASCII keyboard; 1-byte LED output |
| 3 | usage (2 bytes, little-endian) | Consumer control including Home |

Report IDs live in GATT Report Reference descriptors, not notification payloads. The report map lists the keyboard collection first. Only one HID host owns input; a separate debug central can use the custom service. Boot protocol is unsupported. Mouse movement uses 10-unit chunks paced at 15 ms.

A new input session begins with keys/buttons released. Command-peer loss releases input; failed releases must drain before accepting another gesture. App connection, system HID readiness, screen sharing and pointer calibration are separate prerequisites.
