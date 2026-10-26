import Foundation

/// Live progress for the Dynamic Island. SDK action names remain verbatim; native screen reads
/// use Screenshot. Minimal labels shorten long names to leave room for the app icon.
/// `look` is retained for the app's character views and waiting timer state.
struct IslandStatus: Equatable {
    var short: String
    var full: String
    var look: CGPoint?
    var minimal: String? = nil

    var waits: Bool { look == nil }

    static let compactLimit = 16

    static var authorizing: Self {
        Self(short: String(localized: "Allow sharing"), full: String(localized: "Allow screen sharing in the system picker"), look: nil, minimal: String(localized: "Allow"))
    }

    static var captureStopped: Self {
        Self(short: String(localized: "Screen offline"), full: String(localized: "Open the app to restart screen sharing"), look: nil, minimal: String(localized: "Screen"))
    }

    /// Midscene's structured event is the source of truth; a planned action is not yet executing.
    static func progress(_ event: [String: Any]) -> Self? {
        switch event["phase"] as? String {
        case "start": return .looking
        case "plan_thinking": return .planning
        case "plan_planned":
            let detail = event["text"] as? String ?? ""
            return Self(short: "Plan", full: detail.isEmpty ? "Plan" : "Plan · \(clip(detail, 120))", look: .zero, minimal: "Plan")
        case "plan_action":
            let name = (event["action"] as? [String: Any])?["name"] as? String ?? "Action"
            return Self(short: clip("Next: \(name)", compactLimit), full: "aiAct → \(name) · pending", look: nil, minimal: "Next")
        case "action_running", "action_done", "action_failed":
            guard let action = event["action"] as? [String: Any], let name = action["name"] as? String, !name.isEmpty else { return nil }
            let target = action["target"] as? String ?? ""
            let phase = event["phase"] as? String
            let suffix = phase == "action_done" ? " · finished" : phase == "action_failed" ? " · failed" : ""
            let detail = target.isEmpty ? "" : " · \(clip(target, 100))"
            return Self(short: clip(name, compactLimit), full: "aiAct → \(name)\(suffix)\(detail)", look: .zero, minimal: minimalAction(name))
        case "plan_failed": return Self(short: "Plan failed", full: "Plan · failed", look: .zero, minimal: "Plan")
        // Final outcomes are published after Swift has recorded the result and released inputs.
        default: return nil
        }
    }

    private static func minimalAction(_ name: String) -> String {
        switch name {
        case "Tap", "Input", "Swipe", "Scroll", "Home", "Back": return name
        case "LongPress": return "Hold"
        case "KeyboardPress": return "Key"
        case "ClearInput": return "Clear"
        case "DrawPath": return "Draw"
        case "Sleep": return "Wait"
        default: return "Act"
        }
    }

    static var pausedInApp: Self {
        Self(short: String(localized: "Paused"),
             full: String(localized: "Paused while you're here. Go to the Home Screen and I'll go on."),
             look: nil, minimal: String(localized: "Wait"))
    }

    static var looking: Self {
        Self(short: "Screenshot", full: "Screenshot", look: nil, minimal: "Look")
    }

    static var waiting: Self {
        Self(short: String(localized: "Waiting…"), full: String(localized: "Waiting for the model to respond…"),
             look: nil, minimal: String(localized: "Wait"))
    }

    static var planning: Self {
        Self(short: "Plan", full: "aiAct → Plan", look: nil, minimal: "Plan")
    }

    static var help: Self {
        Self(short: String(localized: "Need help"), full: String(localized: "Need your help"), look: .zero, minimal: String(localized: "Help"))
    }

    static var yourTurn: Self {
        Self(short: String(localized: "Your turn"), full: String(localized: "Your turn"), look: CGPoint(x: 0, y: 0.6), minimal: String(localized: "You"))
    }

    /// The end of a run, from its outcome's mood.
    static func ended(_ mood: Mood) -> Self {
        switch mood {
        case .success: return Self(short: String(localized: "Done!"), full: String(localized: "Done!"), look: .zero, minimal: String(localized: "Done"))
        case .failure: return Self(short: String(localized: "Didn't finish"), full: String(localized: "Didn't finish"), look: .zero, minimal: String(localized: "Error"))
        default: return Self(short: String(localized: "Stopped"), full: String(localized: "Stopped"), look: .zero, minimal: String(localized: "Stop"))
        }
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count <= limit ? text : String(text.prefix(max(1, limit - 1))) + "…"
    }

}
