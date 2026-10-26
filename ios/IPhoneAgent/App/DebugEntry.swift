import Foundation

/// Drive the app without touching the phone, for development:
///   iphoneagent://run?task=<urlencoded>   iphoneagent://calibrate   iphoneagent://stop
///   iphoneagent://capture
/// or launch arguments: -run "<task>", -calibrate, -capture
/// (e.g. `xcrun devicectl device process launch --device <id> <bundle id> -run "Open Clock"`).
/// Commands that need input wait up to 30 s for both the board and system HID connection.
/// The URL commands exist in Debug builds only: in a release any web page could open them.
extension AppModel {
    /// True when the URL was a debug command (iphoneagent://run/<id> from the Live Activity is not).
    @discardableResult
    func handleDebug(_ url: URL) -> Bool {
        #if !DEBUG
        return false
        #endif
        guard url.scheme == "iphoneagent", let host = url.host else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func arg(_ name: String) -> String? { query.first { $0.name == name }?.value }
        switch host {
        case "run":
            guard let task = arg("task"), !task.isEmpty else { return false }
            debugCommand("run", task: task)
        case "calibrate", "stop", "capture":
            debugCommand(host)
        case "status":
            say(statusSummary)
        default:
            return false
        }
        return true
    }

    /// A line from the Mac harness, relayed by the board: "run <task>", "calibrate", "stop",
    /// "capture" or "status".
    func handleAppCommand(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let name = parts.first ?? "", rest = parts.count > 1 ? parts[1] : ""
        switch name {
        case "run" where !rest.isEmpty: debugCommand("run", task: rest)
        case "calibrate", "stop", "capture": debugCommand(name)
        case "status": say(statusSummary)
        case "log": relayHistory(Int(rest) ?? 50)
        default: say("debug: unknown app command \"\(line.prefix(40))\"")
        }
    }

    /// "app log <n>": the last n debug.log lines to the harness, paced under the relay's rate limit; a line
    /// is retried while the link is busy.
    func relayHistory(_ n: Int) {
        let lines = DebugLog.tail(min(n, 2000))
        Task { [weak self] in
            for line in lines {
                for _ in 0..<20 {
                    guard let self, self.board.connected else { return }
                    if self.board.commands.relayLog("hist " + line) { break }
                    try? await Task.sleep(nanoseconds: 60_000_000)
                }
                try? await Task.sleep(nanoseconds: 110_000_000)
            }
        }
    }

    /// One line: board, screen sharing, calibration, model and run.
    var statusSummary: String {
        let s = board.status
        let boardText = board.connected ? "connected hid \(s?.inputState ?? "-")"
            : "not connected"
        let mirror = feed.live ? String(format: "live %.2f", feed.aspect) : "off"
        let cal = pointer.span.map { "\($0.w)x\($0.h) " + (pointer.quality.map { String(format: "±%.1f%%", $0 * 100) } ?? "?") }
            ?? "none"
        let model = settings.isConfigured ? (settings.currentModel ?? "auto") : "not set"
        let run = agent.running ? "running step \(agent.steps.count)" : "idle"
        return "status: source ScreenCaptureKit; board \(boardText); sharing \(mirror); calibration \(cal) (\(calibrator.phase)); "
            + "model \(model); run \(run); screen \(Int(DeviceScreen.size.width))x\(Int(DeviceScreen.size.height))"
    }

    /// Launch arguments, once at startup.
    func handleLaunchArguments(_ args: [String] = ProcessInfo.processInfo.arguments) {
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        #if DEBUG
        if let requested = value(after: "-setup"),
           let page = ["connect": SetupPage.connect, "brain": .brain][requested] { setupPage = page }
        if args.contains("-test-model") { Task { await pingLLM() } }
        #endif
        if let task = value(after: "-run") { debugCommand("run", task: task) }
        if args.contains("-calibrate") { debugCommand("calibrate") }
        if args.contains("-capture") { debugCommand("capture") }
    }

    private func debugCommand(_ name: String, task: String = "") {
        say("debug: \(name)\(task.isEmpty ? "" : " \"\(task)\"")")
        Task { [weak self] in
            guard let self else { return }
            switch name {
            case "stop":
                await stopAgent()
            case "run":
                guard await waitReady() else { return say("debug: run not started, Bluetooth mouse not ready in 30 s") }
                guard !agent.running else { return say("debug: a run is already going") }
                tab = .agent
                await run(task)
            case "calibrate":
                guard await waitReady() else { return say("debug: board not ready in 30 s") }
                calibrator.calibrate()
            case "capture":
                await captureTest()
            default:
                break
            }
        }
    }

    /// Board and HID connected; waits up to `timeout` s.
    func waitReady(timeout: Double = 30) async -> Bool {
        if MockMode.on { return true }
        let deadline = now() + timeout
        while now() < deadline {
            let s = board.status
            if board.connected && s?.inputReady == true { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }
}
