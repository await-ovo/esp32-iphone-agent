# Changelog

## Unreleased (fork)

- Replace the board's AirPlay receiver and video forwarding with on-device ScreenCaptureKit capture; requires iOS 27+.
- Use BLE HID mouse and keyboard input so the board only needs power.
- Integrate the [Midscene SDK](https://github.com/web-infra-dev/midscene) for planning, grounding and action selection.
- Adapt pointer calibration, connection recovery, run review and Live Activity to the new capture and input paths.
- Remove the legacy Python server, custom planner/actor prompts and unused migration artifacts.

## Upstream history

This fork builds on [onehumanbeing/esp32-iphone-agent](https://github.com/onehumanbeing/esp32-iphone-agent).
See the upstream repository for releases and earlier architectures.
