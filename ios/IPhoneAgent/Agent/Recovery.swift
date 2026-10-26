import Foundation

/// Input recovery is independent of screen sharing: neither path depends on Wi-Fi or mirroring.
struct Recovery {
    struct Link: Equatable {
        var connected: Bool
        var frameAt: Double
        var hid = true
        var sharing = true
    }
    enum Part: Equatable { case board, mouse, screen }
    struct Stage: Equatable { var part: Part; var ask: Bool }
    enum Next: Equatable { case wait(Stage), live, giveUp(String) }
    static let quiet: [Part: Double] = [.board: 30, .mouse: 20, .screen: 2]
    static let limit = 300.0
    let started: Double
    let limit: Double
    private(set) var stage: Stage?
    private var partSince = 0.0
    init(at t: Double, limit: Double = Self.limit) { started = t; self.limit = limit }

    mutating func next(_ link: Link, at t: Double) -> Next {
        let part: Part? = !link.connected ? .board : !link.hid ? .mouse
            : !link.sharing || link.frameAt <= started ? .screen : nil
        guard let part else { stage = nil; return .live }
        if part != stage?.part { partSince = t }
        stage = Stage(part: part, ask: t - partSince >= Self.quiet[part]!)
        if t - started >= limit { return .giveUp(Self.reason(part)) }
        return .wait(stage!)
    }

    static func reason(_ part: Part) -> String {
        switch part {
        case .board: return String(localized: "The board did not reconnect.")
        case .mouse: return String(localized: "The Bluetooth mouse did not reconnect.")
        case .screen: return String(localized: "Screen sharing is unavailable. Open the app to share the screen again.")
        }
    }
}

extension Recovery.Stage {
    var status: IslandStatus {
        switch part {
        case .board: return IslandStatus(short: String(localized: "Reconnecting…"), full: String(localized: "Waiting for the board…"), look: nil)
        case .mouse: return IslandStatus(short: String(localized: "Mouse offline"), full: String(localized: "Waiting for the mouse…"), look: nil)
        case .screen: return .captureStopped
        }
    }
    var line: String {
        switch part {
        case .board: return String(localized: "Check the board's power. The task resumes after it reconnects.")
        case .mouse: return String(localized: "Connect ESP32 Agent in Settings › Accessibility › Touch › AssistiveTouch › Devices › Bluetooth Devices.")
        case .screen: return String(localized: "Open ESP32 Agent and allow screen sharing to continue.")
        }
    }
    var logLine: String { line }
}
