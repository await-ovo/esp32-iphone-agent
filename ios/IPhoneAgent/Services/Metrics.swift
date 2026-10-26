import Foundation

/// Live numbers for the Diagnostics page; a snapshot goes into every trace (metrics.json).
@MainActor final class Metrics: ObservableObject {
    struct Step: Codable { var frameMs = 0.0, llmMs = 0.0, hidMs = 0.0 }

    // board, from status
    @Published var board: BoardStatus?
    @Published var statusAge = 0.0  // s since the last status notify
    @Published var mtu = 0
    @Published var fps = 0.0
    @Published var captureMs = 0.0
    @Published var frameAge = 0.0
    @Published var screenshotMs: Double?
    // agent
    @Published var steps: [Step] = []
    @Published var llmFirstMs: Double?
    @Published var llmTotalMs: Double?
    @Published var llmPingMs: Double?
    @Published var hidMs: [String: Double] = [:]  // last round trip per command
    // background
    @Published var backgroundSince: Double?
    @Published var backgroundAlive = 0.0  // s alive in background (current or last stint)
    @Published var suspensions = 0

    private var windowFrames = 0
    private var windowStart = now()
    private var lastTick = now()
    private var lastStatus: Double?

    func status(_ s: BoardStatus) {
        board = s
        lastStatus = now()
    }

    func frameCaptured(ms: Double, age: Double) {
        windowFrames += 1
        captureMs = ms; frameAge = age
    }
    func llm(first: Double?, total: Double) {
        llmFirstMs = first.map { $0 * 1000 }
        llmTotalMs = total * 1000
    }
    func step(_ s: Step) {
        steps = Array((steps + [s]).suffix(40))
        DebugLog.write(String(format: "step %d timing: frame %.0f ms, LLM %.0f ms, HID %.0f ms", steps.count, s.frameMs,
                              s.llmMs, s.hidMs))
    }

    /// Called every second by a timer; also detects suspension (a gap far longer than the tick).
    func tick() {
        let t = now()
        if t - lastTick > 5 { suspensions += 1 }
        lastTick = t
        let span = max(t - windowStart, 0.001)
        fps = Double(windowFrames) / span
        windowFrames = 0; windowStart = t
        statusAge = lastStatus.map { t - $0 } ?? 0
        if let since = backgroundSince { backgroundAlive = t - since }
    }

    func enteredBackground() { backgroundSince = now(); backgroundAlive = 0 }
    func enteredForeground() { backgroundSince = nil }

    /// Everything as JSON-ready values, for metrics.json.
    func snapshot() -> [String: Any] {
        var out: [String: Any] = [
            "screen_source": "ScreenCaptureKit", "mtu": mtu, "fps": fps, "jpeg_ms": captureMs, "frame_age_s": frameAge,
            "background_alive_s": backgroundAlive, "suspensions": suspensions, "hid_ms": hidMs,
            "steps": steps.map { ["frame_ms": $0.frameMs, "llm_ms": $0.llmMs, "hid_ms": $0.hidMs] },
        ]
        out["screenshot_ms"] = screenshotMs
        out["llm_first_ms"] = llmFirstMs
        out["llm_total_ms"] = llmTotalMs
        if let board, let data = try? JSONEncoder().encode(board) {
            out["board"] = try? JSONSerialization.jsonObject(with: data)
        }
        return out
    }
}
