# Midscene on iPhone

The app uses [Midscene](https://github.com/web-infra-dev/midscene) through the published `@midscene/core` and `@midscene/shared` **1.16.1** packages as its only agent. Swift owns ScreenCaptureKit frames, HID, calibration, lifecycle, and local history. A local WKWebView runs the SDK; it does not control the phone through a DOM or require Node at runtime.

## Build

Requires iOS 27+, Xcode 27+, Node 22+, and pnpm 10.

```sh
pnpm --dir ios/Midscene install --frozen-lockfile
pnpm --dir ios/Midscene build
pnpm --dir ios/Midscene test
open ios/IPhoneAgent.xcodeproj
```

The generated bundle lives in `ios/Midscene/Resources/Midscene` and is ignored by Git. Rebuild it after JS changes, before building or archiving in Xcode. `ios/project.yml` includes that directory as a folder resource. The build uses the unchanged npm packages, browser shims, and bundled Photon WASM; Node-only filesystem, subprocess, networking-server and Sharp paths throw if reached. No repository-source SDK build or remote JS download is involved.

Configure the endpoint, model ID, key and **Midscene model family** in the shared onboarding/settings model form. Family is a Midscene adapter name, such as `doubao-seed`, `qwen3-vl` or `gpt-5`, not necessarily the endpoint's model ID. Existing endpoint/key/model values are preserved; old planner/actor overrides are no longer read. Model requests use URLSession with streaming byte delivery, cancellation and HTTP status propagation. Extra body settings pass to Midscene; an explicit token-parameter override renames `max_tokens` on outgoing requests. Keys remain in Keychain and are passed only to the current runtime.

## iPhone context

`ios/Midscene/runtime/context.ts` holds the shared iPhone navigation and interaction rules, supplied through the official `aiContexts.aiAct` Agent option. Every new Agent, including a continuation after user intervention, receives these rules. They cover app search, the existing Home action, screen feedback, ASCII input and focus, controls, scrolling, avoiding the agent's own UI, and uncertain or incomplete actions. Home is preferred over manually composing a bottom-edge swipe; the model must inspect the resulting screenshot.

Saved-task checklists remain in the task prompt alongside the user's goal. Do not pass them as a standalone `aiAct(..., { context })`: a per-call context replaces `aiContexts.aiAct` instead of merging with it. `PhoneDevice.describe()` is interface metadata, not AI guidance. The legacy `THINK`/`DO` format and 0…1000 action protocol are not included in the context; Midscene owns its model protocol. Rebuild the JS bundle after editing the context.

## Actions

| Action | Swift execution |
|---|---|
| Tap | Calibrated pointer movement, click |
| LongPress | Move, press, wait, release |
| Swipe | Midscene SDK resolves relative/end-point form and repetitions; Swift performs each pressed stroke |
| Scroll | Finger-like swipe toward offscreen content; boundary modes perform five swipes |
| Input | Optional focus tap; replace = Cmd+A, Backspace, type; typeOnly = type; clear = Cmd+A, Backspace |
| ClearInput | Optional focus tap, Cmd+A, Backspace |
| KeyboardPress | Optional focus tap; key names mapped to the existing HID names |
| Home / Back | Existing system Home command / left-edge back gesture |
| DrawPath | One pressed stroke through screenshot pixel coordinates |
| Sleep | Midscene's built-in cancellable wait |

No extra editable-element, focus, keyboard-visibility or successful-clearing checks are performed. Unsupported keys/text surface the firmware's error. The current board supports ASCII typing. Midscene input options for per-character delay and automatic keyboard dismissal are not implemented by this HID adapter; use KeyboardPress or a separate UI action when needed. Gesture duration is a minimum, not an exact timing guarantee: Bluetooth transport and firmware movement pacing add time.

The device `size()` matches the JPEG's pixel dimensions. SDK coordinates become Pointer fractions; trace overlays use the existing 0…1000 coordinates. Calibration and rehoming remain necessary. ScreenCaptureKit supplies the screenshots directly on the iPhone; WKWebView snapshots and BLE video are not used.

## History and storage

Each run is in **Documents/traces/<timestamp>** (a suffix prevents same-second collisions):

- `steps.jsonl`: task, selected model screenshots with source frame ID/capture time/dimensions, Midscene progress events, action starts/updates, timing, compact semantic summaries, usage, recovery and terminal status.
- Content-hashed `.jpg` files: identical screenshots share one file. Action starts retain the device screenshot and dimensions associated with execution. Terminal records retain the latest screenshot.
- `metrics.json`: native diagnostics. User review annotations remain in `review.json`.

Open **Runs → a task** for the existing native step viewer, status, overlays, corrections and export. An action start and its updates form one card. Input's focus/clear/type operations remain one card. Incomplete actions remain visible if the app exits. Historical step traces still load; the video-review path has been removed. New runs do not record continuous video.

`cache`, `generateReport` and `autoPrintReportMsg` are disabled. There is no dump listener, dump serialization request or HTML report export. The SDK still retains internal execution/screenshot state during a task. Runs are limited to 40 top-level actions and 40 planning cycles per attempt; a new SDK Agent is used for each user-approved continuation, and the WKWebView is discarded when the run ends. This limits growth; it is not a guarantee against iOS memory termination.

## Background and stopping

The app calibrates if needed and prepares WebKit in the foreground, then presents the system full-display picker for a new task-owned sharing session. Until the person authorizes it, there is no departure animation, Home input or model execution. The official picker callback supplies the content filter; `SCStream.startCapture()` and the first usable frame establish capture readiness. Startup then leaves through system HID input (consumer Home, Cmd+H, then a home-bar flick as fallback) and checks that UIKit actually reports background. A board acknowledgement alone is insufficient. If the system sharing panel still covers the app, leaving Home dismisses it without OCR or coordinate-based panel clicks. The departure animation only runs when the app is active and visible. A post-departure frame is required before `aiAct` runs. No continued-processing task is registered or submitted.

Onboarding explains per-task consent rather than requiring screen sharing ahead of time. Manual sharing remains a diagnostics tool. Returning to the agent app pauses task input. Terminal cleanup stops capture before publishing completion.

`ScreenCaptureFeed` samples complete screen frames at most four times per second on a serial queue, converts with software Core Image to a JPEG (width at most 960, quality 0.75), and replaces its latest snapshot. It does not attach `SCRecordingOutput` or `SCClipBufferingOutput`, create MP4 files, retain video history, or transmit screen frames over BLE. Frame `displayTime` is converted from mach absolute time to the host clock and mapped to the action clock; receipt time cannot make an old frame fresh.

A Midscene screenshot selects an immutable JPEG and its metadata. An active native stream may retain unchanged pixels without expiring them after two seconds. Blank, suspended and stopped frame statuses invalidate the image; stream errors and user stop clear the session. Startup and recovery image barriers still require content displayed after the transition. Model snapshots prefer a post-action frame but may observe the unchanged image after a short settling interval; its original capture timestamp is preserved. A snapshot wait is bounded to five seconds. Stop invalidates cached frames and rejects outstanding screenshots before stopping the stream. Run completion awaits capture cleanup before publishing the terminal UI and releasing the run for another start. Selected model screenshots and action/terminal records share content-hashed JPEGs in the native trace. The Home preview uses the selected model image, avoiding a recursively captured live preview of the agent itself.

App connection, system HID readiness and live screen sharing are checked independently. Loss pauses input and gives recovery instructions. Restarting screen sharing requires foreground user consent. A changed screenshot geometry forces reobservation before input.

The Dynamic Island consumes official `addProgressListener` events: planning, plan ready, action preparing, action running, action done and failure are distinct. Planned actions are not presented as already executing. The trace stores compact phase/name/target/timing metadata, not raw SDK dumps. The counter shows actions rather than an invented percentage of the user's goal. Demo mode emits the same planning and action progress payloads into the shared presentation mapper, so its Live Activity uses the same English action names without invoking the SDK or sending input.

Task status is presented through the app's Live Activity. Ordinary run notifications use passive delivery and notification-list-only foreground presentation, with no sound. Finished custom activities are dismissed immediately; an app relaunch clears its abandoned custom activities. The app no longer requests `BGContinuedProcessingTask`, so tasks do not create its separate system progress card. The app's custom Live Activity and the system screen-sharing privacy indicator remain; iOS controls their presentation.

The production minimal presentation pairs an 18-point vector character with a short English status in a 36 × 20-point row. On-device verification on iPhone 15 Plus during full-display sharing showed the character and complete Plan label together; the observation-only task finished successfully and capture stopped. This device run did not verify longer labels such as Input or Swipe. The compact presentation puts the character and status on separate sides. While waiting, native low-rate gaze updates move its eyes; the expanded presentation keeps the full action name, target and count. No timeline animation or video capture output is added. Temporary device-probe commands and snapshot-preview code were removed after verification.

Stop cancels native bridge tasks and HTTP, blocks further side effects, aborts the SDK and releases a pressed pointer. WebContent termination ends the run; there is no automatic replay/restart. A command already delivered to the board may have partially executed. Timed-out HID commands are never blindly retried by the transport.

The app uses the authorized `screen-capture` session and `bluetooth-central` background modes, with no continued-processing scheduler or `processing` background mode. `.inactiveSchedulingPolicy = .none` prevents idle, detached WebViews from being suspended by that scheduling policy; it does not grant background execution by itself. Long unattended runs and memory behavior still require device validation; a simulator test cannot establish this guarantee. Launching a task while already backgrounded must bring the app to the foreground first.

## Verification

Apple's [iOS capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios) declares `screen-capture` for full-display background streaming; its separate `audio` mode supports microphone capture, which this app does not request. That documents capture, not an unlimited guarantee for WebKit/model execution. The SDK picker has no public `dismiss` selector. Its `isActive` property enables system sharing interaction; the documentation does not promise a panel-only dismissal that preserves capture.

JS tests exercise Midscene action helper behavior, error propagation and native fetch streaming/cancellation. XCTest covers native input order, coordinate conversion, trace folding/deduplication, recovery, and the published SDK running two actions in WKWebView against a local SSE response fixture, including iPhone context and task hints in each planning request. No real model credentials are used by these tests.

For a device smoke test: build the app, configure a matching model family, connect/calibrate the board, allow full-display sharing in the system picker and run a short Home/Settings task. Check action positions, foreground pause/stop, the screen-sharing privacy indicator, the custom Live Activity and the resulting native history. Update both the app and HID-only firmware when migrating from AirPlay: the video/network GATT characteristics have been removed.
