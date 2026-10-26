# Export runs for agent review

A run export contains the selected screenshots, action records, progress and timing events, and saved user annotations. Give the raw ZIP to an agent for analysis; no dataset conversion is required.

## Export one run or a batch

1. Finish or stop the task, then open it in **Runs**.
2. Add any **Correct / Wrong**, corrected tap points or notes. These edits are saved in `review.json`.
3. Open **⋯ → Export trace** and use the share sheet to save the ZIP to Files or transfer it to your Mac.

This exports the run folder as it is, including original screenshots and typed text. The **Keep run data for sharing** switch is not required. Keep raw archives private when they contain personal screen content.

For a batch, use **Settings → Diagnostics → Export traces**. This includes older runs beyond the 30 shown in the list. **Settings → About → Logs → Export all logs** also includes the rest of Documents, such as debug logs, crash reports and demonstration recordings.

## Copy over USB

On a paired iPhone, open **Finder → iPhone → Files → ESP32 Agent** and copy the `traces` folder. For a development installation whose container is accessible, you can also use Xcode's command-line tool:

```bash
xcrun devicectl device copy from \
  --device '<device identifier>' \
  --domain-type appDataContainer \
  --domain-identifier '<installed app bundle ID>' \
  --source Documents/traces \
  --destination ./run-export/traces
```

Use your installed app's bundle ID from the build configuration.

## Archive contents

A run lives under `Documents/traces/<yyyyMMdd-HHmmss>/`, with a suffix if the timestamp collides. ZIP wrapper directories vary by export path; locate a run by its `steps.jsonl`.

```text
<run>/
  steps.jsonl
  <frame>.jpg       # content-hashed or numbered screenshot
  metrics.json      # when a diagnostics snapshot was written
  review.json       # when review edits were saved
```

| Record or file | Meaning |
|---|---|
| `steps.jsonl` | One JSON object per event. `n` is the event sequence, `t` is epoch seconds and `kind` identifies the event type. |
| `kind=screenshot` | Selected model screenshot with frame ID, source capture time and dimensions; `frame` names its JPEG. Repeated screenshots share the same content-hashed file. |
| `kind=progress` | Compact [Midscene](https://github.com/web-infra-dev/midscene) phase, action and target information. |
| `kind=step` | Action start or terminal outcome. Version 2 records use their explicit `frame` reference. |
| `kind=step-update` | Parameters, status and completion information for an existing action. Merge these fields into the step with the same action `id`; preserve the original frame and start time. |
| `kind=usage` | Model ID, token usage and elapsed model-call time. |
| Other events | Startup timing and recovery information, when present. |
| `review.json` | User verdicts, corrected point `fix`, notes, inserted or uncertain steps, edited task prompt and hints. Each saved step's `action` is a JSON string requiring a second JSON decode. |
| Root JPG files | Original selected images. Tap/swipe and correction overlays are drawn by the app. Their coordinates use 0–1000 screen units. |
| `metrics.json` | Native capture, BLE, model and background diagnostics; not a replacement for the event log. |

New runs do not save continuous video or a `video/` frame directory, full SDK dumps, model reasoning, or complete model request/response bodies. Older imported traces can have a different format.

Suggested handoff:

> Read steps.jsonl and merge step-update events by action id. Inspect referenced screenshots and review.json for my corrections and notes. Report observations with the run ID, event n and image filename. Distinguish my annotations from model output and your own conclusions.

## Redacted sharing export

**Settings → Privacy → enable Keep run data for sharing → select runs → Prepare Export** creates a separate archive. It processes text to hide selected values and typed action text in supported formats, blacks out the top 7% of images and re-encodes the JPGs. It includes saved reviews, but does not guarantee all personal content is removed. Inspect the archive before sharing. Use raw exports when analysis requires original images and text.

## Interpretation limits

- A terminal `done` is the agent's claim, rather than an independent human success judgment. User verdicts and notes are separate evidence.
- Review steps can be inserted or deleted. Match the saved action/frame/time instead of joining by array index.
- An action screenshot shows the input used for that action. Inspect later screenshots and recorded status for effects; selected frames are not a continuous recording.
- Exports support inspection, but do not reproduce every original model request exactly.
- A demonstration under `Documents/recordings` contains keyframes and inferred actions, rather than measured finger touches. The all-logs export includes it; the traces-only batch does not.

Implementation: [trace writing](../ios/IPhoneAgent/Services/TraceStore.swift), [agent events](../ios/IPhoneAgent/Agent/MidsceneController.swift), [trace loading](../ios/IPhoneAgent/Services/Stores.swift), [review export](../ios/IPhoneAgent/Review/ReviewView.swift), [annotations](../ios/IPhoneAgent/Review/ReviewModel.swift), and [sharing export](../ios/IPhoneAgent/Services/RunShare.swift).
