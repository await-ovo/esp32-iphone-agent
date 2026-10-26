import Foundation

struct BlindError: LocalizedError {
    var reason = "Screen sharing is unavailable. Open the app to share the screen again."
    var errorDescription: String? { reason }
}

/// Native run state and history. Midscene owns planning, grounding, and action selection.
@MainActor final class MidsceneController: ObservableObject {
    let phone: Gestures?
    let screen: ScreenSource?
    let trace: TraceStore?
    let maxSteps: Int
    var metrics: Metrics?
    @Published private(set) var runtime: MidsceneRuntime?
    @Published private(set) var task = ""
    @Published private(set) var plan = ""
    @Published private(set) var selectedFrame: Data?
    @Published var steps: [JObject] = []
    @Published private(set) var running = false
    private(set) var lastActed = 0.0
    var hints: [String] = []
    var gate: (() async throws -> Void)?
    var link: (() -> Recovery.Link)?
    var onRecover: ((Recovery.Stage?) -> Void)?
    var restore: (() async throws -> Void)?
    var recoveryLimit = Recovery.limit
    var onFinish: (() -> Void)?
    var onCleanup: (() async -> Void)?
    var onStep: (() -> Void)?
    var onDoing: ((Doing) -> Void)?
    var onHelp: ((String) async -> HelpChoice)?
    enum Doing { case looking, waiting, progress(IslandStatus) }
    enum HelpChoice { case resume, skip, stop }
    private var device: MidsceneDevice?
    private var config: [String: Any] = [:]
    private var job: Task<Void, Never>?
    private var prepared = false
    private var pending: Int?
    private var actionStarted = 0.0
    private var actions = 0
    private var thought = ""
    private var modelMs = 0.0
    private var report: JObject = [:]

    init(phone: Gestures?, screen: ScreenSource?, trace: TraceStore?, maxSteps: Int = 40) {
        self.phone = phone; self.screen = screen; self.trace = trace; self.maxSteps = maxSteps
    }

    func prepare(_ settings: Settings) async throws {
        guard !running, runtime == nil else { throw DeviceError(message: "agent already running") }
        let family = settings.modelFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !family.isEmpty else { throw DeviceError(message: String(localized: "Choose the Midscene model family in Settings.")) }
        config = ["baseURL": settings.baseURL, "model": try await settings.resolvedModel(), "family": family,
                  "apiKey": settings.apiKey, "extra": settings.extra, "tokenParam": settings.tokenParam, "maxSteps": maxSteps]
        guard let phone else { throw DeviceError(message: "No phone connected") }
        device = MidsceneDevice(phone: phone)
        device?.beforeGesture = { [weak self] in
            guard let self else { throw CancellationError() }
            try await gate?()
            if let feed = screen as? ScreenCaptureFeed, device?.size != feed.size {
                throw DeviceError(message: "Screen dimensions changed. Inspect a fresh screenshot before acting.")
            }
        }
        let runtime = MidsceneRuntime()
        self.runtime = runtime
        runtime.handle = { [weak self] method, params in
            guard let self else { throw CancellationError() }
            return try await self.receive(method, params)
        }
        do {
            try await runtime.prepare()
            try Task.checkCancellation()
            prepared = true
        } catch { close(); throw error }
    }

    func start(_ task: String, traceStarted: Bool = false) throws {
        guard !running, prepared else { throw DeviceError(message: "Midscene has not been prepared") }
        guard screen?.live == true else { throw BlindError() }
        self.task = task; plan = ""; steps = []
        selectedFrame = nil
        report = [:]
        lastActed = 0; actions = 0; thought = ""; pending = nil; modelMs = 0
        metrics?.steps = []; metrics?.llmFirstMs = nil; metrics?.llmTotalMs = nil
        if !traceStarted { trace?.start(task: task) }
        running = true
        job = Task { [weak self] in
            guard let self else { return }
            await run()
            await onCleanup?()
            running = false
            job = nil
            close()
            onFinish?()
        }
    }

    func stop() {
        prepared = false
        job?.cancel()
        runtime?.stop()
        if job == nil { running = false; close() }
    }

    func close() {
        prepared = false
        runtime?.close(); runtime = nil
        device = nil; config = [:]
    }

    func clear() throws {
        guard !running else { throw DeviceError(message: "stop the agent first") }
        task = ""; plan = ""; steps = []
    }

    var prompt: String {
        hints.isEmpty ? task : task + "\n\nHints for this task:\n" + hints.map { "- " + $0 }.joined(separator: "\n")
    }

    private func run() async {
        do {
            guard let runtime else { throw DeviceError(message: "Runtime missing") }
            var instruction = prompt
            for attempt in 0...2 {
                onDoing?(.waiting)
                let result = try await runtime.run(config.merging(["prompt": instruction]) { _, new in new })
                try Task.checkCancellation()
                if result["ok"] as? Bool == true {
                    record(["action": .str("done"), "answer": .str(result["answer"] as? String ?? "")], frame: device?.frame)
                    break
                }
                if result["stopped"] as? Bool == true { throw CancellationError() }
                let reason = safe(result["error"] as? String ?? "Midscene did not finish")
                finishAction(error: reason)
                guard attempt < 2, actions < maxSteps, let onHelp else { throw DeviceError(message: reason) }
                record(["action": .str("help"), "reason": .str(reason)])
                let choice = await onHelp(reason)
                try Task.checkCancellation()
                if choice == .stop { throw CancellationError() }
                let note = choice == .resume ? "The user intervened. Inspect the current screen and continue." : "The user asked to skip the blocked step and continue."
                record(["action": .str(choice == .resume ? "takeover" : "skipped"), "reason": .str(note)])
                instruction = continuationPrompt(note: note, reason: reason)
            }
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            let reason = cancelled ? "Task stopped; an in-flight action may have partially completed" : safe(error.localizedDescription)
            finishAction(error: reason)
            record(["action": .str(cancelled ? "stopped" : "fail"), "reason": .str(reason)], frame: device?.frame)
        }
        if let metrics { trace?.writeMetrics(metrics.snapshot()) }
    }

    private func safe(_ text: String) -> String {
        let key = config["apiKey"] as? String ?? ""
        return String((key.isEmpty ? text : text.replacingOccurrences(of: key, with: "[redacted]")).prefix(2000))
    }

    func continuationPrompt(note: String, reason: String) -> String {
        let history = steps.filter { $0["sdkAction"] != nil }.map { step in
            Actions.key(step).merging(["status": step["status"] ?? .str("unknown"), "thought": step["thought"] ?? .str("")])
        }
        return prompt + "\n\n" + note + "\nPrevious attempt: " + reason
            + "\nPrevious action history (completed means dispatched, not visually verified):\n" + PyJSON.dumps(.arr(history.map { .obj($0) }), ascii: false)
            + "\nContinue from the current screen. Do not repeat completed effects. A failed action may have partially executed; inspect before retrying."
    }

    private func record(_ step: JObject, frame: Data? = nil) {
        let index = steps.count
        var step = step.merging(["id": .int(index), "t": .num(now()), "traceVersion": .int(2)])
        if let frame {
            if let name = trace?.saveFrame(frame) { step["frame"] = .str(name) }
            step = step.merging(device?.frameMetadata ?? [:])
        }
        steps.append(step)
        trace?.write(kind: "step", step)
        onStep?()
    }

    private func update(_ fields: JObject) {
        guard let pending else { return }
        steps[pending] = steps[pending].merging(fields)
        trace?.write(kind: "step-update", fields.merging(["id": .int(pending)]))
        onStep?()
    }

    private func finishAction(error: String? = nil) {
        guard pending != nil else { return }
        var fields: JObject = ["status": .str(error == nil ? "completed" : "failed"), "act_s": .num(now() - actionStarted)]
        if let error { fields["reason"] = .str(safe(error)) }
        update(fields)
        pending = nil
    }

    private func readyToLook() async throws {
        try Task.checkCancellation()
        try await gate?()
        if let seconds = try await waitForScreen() {
            record(["action": .str("reconnected"), "reason": .str(String(format: "connection restored after %.0f s", seconds))])
            try await gate?()
        }
        try Task.checkCancellation()
    }

    private func receive(_ method: String, _ p: [String: Any]) async throws -> Any {
        try Task.checkCancellation()
        guard running, let device else { throw CancellationError() }
        switch method {
        case "screenshot":
            DebugLog.write("midscene: screenshot requested")
            try await readyToLook()
            onDoing?(.looking)
            let frame: Data
            var metadata: JObject = [:]
            if let feed = screen as? ScreenCaptureFeed {
                let snapshot = try await feed.snapshot(after: lastActed > 0 ? lastActed : nil)
                frame = snapshot.jpeg; metadata = snapshot.metadata
            }
            else if let image = screen?.frame { frame = image }
            else { throw BlindError() }
            let image = try device.capture(frame, metadata: metadata)
            selectedFrame = frame
            var event = metadata
            if let file = trace?.saveFrame(frame) { event["frame"] = .str(file) }
            trace?.write(kind: "screenshot", event)
            DebugLog.write("midscene: screenshot delivered")
            return image
        case "size":
            if device.frame == nil { _ = try await receive("screenshot", [:]) }
            return ["width": device.size.width, "height": device.size.height]
        case "actionBegin":
            try await gate?()
            if let feed = screen as? ScreenCaptureFeed, device.frame != nil, device.size != feed.size {
                throw DeviceError(message: "Screen dimensions changed. Inspect a fresh screenshot before acting.")
            }
            if try await waitForScreen() != nil {
                throw DeviceError(message: "Connection restored. Inspect a fresh screenshot before acting.")
            }
            try Task.checkCancellation()
            guard actions < maxSteps else { throw DeviceError(message: "Action limit reached (\(maxSteps))") }
            finishAction(error: "Action interrupted")
            actions += 1
            actionStarted = now()
            let name = p["name"] as? String ?? ""
            let names = ["Tap": "tap", "LongPress": "longpress", "Swipe": "swipe", "Scroll": "scroll", "Input": "type",
                         "ClearInput": "clear", "KeyboardPress": "key", "DrawPath": "path", "Home": "home", "Back": "back", "Sleep": "wait"]
            var fields: JObject = ["action": .str(names[name] ?? name), "sdkAction": .str(name), "status": .str("running"),
                    "thought": .str(thought), "think_s": .num(modelMs / 1000), "frameWidth": .num(device.size.width), "frameHeight": .num(device.size.height)]
            if report["sdkAction"]?.str == name { fields = fields.merging(report) }
            if let param = p["param"] as? [String: Any] { fields["sdkParam"] = PyJSON.from(param) }
            record(fields, frame: device.frame)
            report = [:]
            pending = steps.count - 1
            if let time = p["timeMs"] as? Double { update(["duration": .num(time / 1000)]) }
        case "actionEnd":
            let error = p["error"] as? String
            let hidMs = (now() - actionStarted) * 1000
            finishAction(error: error)
            let settled = now()
            if error == nil { onDoing?(.looking); await screen?.afterAction(since: lastActed) }
            metrics?.step(Metrics.Step(frameMs: (now() - settled) * 1000, llmMs: modelMs, hidMs: hidMs))
            modelMs = 0
        case "progress":
            DebugLog.write("midscene: phase \(p["phase"] as? String ?? "unknown")")
            let text = safe(p["text"] as? String ?? "")
            if !text.isEmpty { thought = text; plan = text }
            if let status = IslandStatus.progress(p) { onDoing?(.progress(status)) }
            var event: JObject = ["phase": .str(p["phase"] as? String ?? ""), "sequence": .num(p["sequence"] as? Double ?? 0)]
            if let action = p["action"] as? [String: Any] {
                event["name"] = .str(action["name"] as? String ?? "")
                if let target = action["target"] as? String { event["target"] = .str(safe(target)) }
            }
            if let index = p["planIndex"] as? Int { event["planIndex"] = .int(index) }
            if !text.isEmpty { event["text"] = .str(text) }
            if let action = p["action"] as? [String: Any] {
                if let param = action["param"] { event["sdkParam"] = PyJSON.from(param) }
                if let point = action["point"] { event["sdkPoint"] = PyJSON.from(point) }
            }
            if event["phase"]?.str == "plan_thinking" { report = [:] }
            if event["phase"]?.str == "action_running" {
                report = event.without(["phase", "sequence", "name"])
                report["sdkAction"] = event["name"]
            }
            if let duration = p["durationMs"] as? Double { event["duration_ms"] = .num(duration) }
            if let error = p["error"] as? String { event["error"] = .str(safe(error)) }
            trace?.write(kind: "progress", event)

        case "usage":
            DebugLog.write("midscene: model call completed")
            let ms = p["milliseconds"] as? Double ?? 0
            modelMs += ms
            metrics?.llm(first: nil, total: ms / 1000)
            trace?.write(kind: "usage", ["model": .str(p["model"] as? String ?? ""), "tokens": .num(p["tokens"] as? Double ?? 0),
                                        "milliseconds": .num(ms)])
        default:
            guard let pending else { throw DeviceError(message: "Action has not started") }
            let repeats = (steps[pending]["repeat"]?.int ?? 0) + 1
            try await device.execute(method, p) { [weak self] fields in
                self?.update(method == "swipe" ? fields.merging(["repeat": .int(repeats)]) : fields)
            }
            if method == "swipe" { update(["completedRepeat": .int(repeats)]) }
            lastActed = now()
        }
        return NSNull()
    }
    func waitForScreen(poll: Double = 0.5) async throws -> Double? {
        guard let screen else { return nil }
        let state = link?()
        if screen.live && (state.map { $0.connected && $0.hid && $0.sharing } ?? (phone?.device.connected ?? true)) { return nil }
        var recovery = Recovery(at: now(), limit: recoveryLimit)
        var shown: Recovery.Stage?
        defer { if shown != nil { onRecover?(nil) } }
        while true {
            try Task.checkCancellation()
            let state = link?() ?? Recovery.Link(connected: phone?.device.connected ?? true, frameAt: screen.live ? now() : 0, sharing: screen.live)
            switch recovery.next(state, at: now()) {
            case .live where screen.live:
                try await restore?()
                await screen.settled()
                return now() - recovery.started
            case .live: break
            case .wait(let stage):
                if stage != shown { shown = stage; onRecover?(stage) }
            case .giveUp(let reason):
                throw BlindError(reason: reason)
            }
            try await Task.sleep(nanoseconds: UInt64(poll * 1e9))
        }
    }

    func showMock(task: String, plan: String, steps: [JObject], running: Bool) {
        self.task = task
        self.plan = plan
        self.steps = steps
        self.running = running
    }

}
