import Foundation

/// Self-healing runs: a lost board, HID or screen sharing pauses the run (MidsceneController.waitForScreen); this side
/// reports each stage (log, Live Activity, in-app banner, a notification when the user has to act) and
/// restores the board's state once the screen is live again.
extension AppModel {

    func wireRecovery() {
        agent.link = { [unowned self] in
            Recovery.Link(connected: board.connected, frameAt: feed.capturedAt,
                          hid: board.status?.inputReady == true, sharing: feed.live)
        }
        agent.onRecover = { [weak self] stage in self?.recover(stage) }
        agent.restore = { [weak self] in try await self?.restoreRun() }
    }

    func recover(_ stage: Recovery.Stage?) {
        let was = recovering
        recovering = stage
        guard let stage else {
            notifier.clearLinkAsks()
            runMood = .thinking
            return
        }
        if was == nil { recoverySince = Date() }
        if stage.part != .board, was == nil || was?.part == .board, let up = board.status?.up, up < 60_000 {
            DebugLog.write("recover: board rebooted \(up / 1000) s ago (reset: \(board.status?.rst ?? "?"))")
        }
        DebugLog.write("recover: \(stage.logLine)")
        runMood = .listening
        live.update(mood: .listening, step: moveCount, line: stage.line, phase: .running, status: stage.status)
        if stage.ask { notifier.post(kind(stage.part), title: title(stage.part), body: stage.line, run: runID) }
    }

    /// Live again: the board may have rebooted with unknown input state and the screen moved on.
    func restoreRun() async throws {
        DebugLog.write(String(format: "recover: live again after %.0f s", Date().timeIntervalSince(recoverySince)))
        _ = try await feed.image(after: recoverySince.timeIntervalSince1970)
        try await pointer.reset()  // a gesture cut off mid-way may have left the button down
        DebugLog.write("recover: button released, pointer re-homed; going on from step \(moveCount)")
        live.update(mood: .thinking, step: moveCount, line: String(localized: "Back online. Going on from here…"),
                    phase: .running, status: .looking)
    }

    private func kind(_ part: Recovery.Part) -> Notifier.Kind {
        switch part {
        case .board: return .board
        case .mouse: return .mouse
        case .screen: return .capture
        }
    }

    private func title(_ part: Recovery.Part) -> String {
        switch part {
        case .board: return String(localized: "Board disconnected")
        case .mouse: return String(localized: "Mouse disconnected")
        case .screen: return String(localized: "Allow screen sharing to continue")
        }
    }
}
