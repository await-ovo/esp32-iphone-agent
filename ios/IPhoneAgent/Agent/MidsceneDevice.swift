import UIKit

@MainActor protocol Gestures: AnyObject {
    var device: HIDDevice { get }
    func tap(_ x: Double, _ y: Double, aim: Bool) async throws
    func stroke(_ points: [CGPoint], duration: Double, hold: Bool) async throws
    func type(_ text: String) async throws
    func key(_ combo: String) async throws
    func goHome() async throws
    func goBack() async throws
}
extension Pointer: Gestures {}

/// SDK pixels → Pointer fractions → review coordinates (0…1000). No input-element heuristics.
@MainActor final class MidsceneDevice {
    let phone: Gestures
    private(set) var frame: Data?
    private(set) var frameMetadata: JObject = [:]
    private(set) var size = CGSize.zero
    var beforeGesture: (() async throws -> Void)?

    init(phone: Gestures) { self.phone = phone }

    func capture(_ data: Data, metadata: JObject = [:]) throws -> String {
        guard let image = UIImage(data: data)?.cgImage else { throw DeviceError(message: "Invalid screen JPEG") }
        frame = data
        frameMetadata = metadata
        size = CGSize(width: image.width, height: image.height)
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    func point(_ value: [String: Any]) throws -> CGPoint {
        guard size.width > 0, size.height > 0, let x = value["x"] as? Double, let y = value["y"] as? Double,
              x.isFinite, y.isFinite else { throw DeviceError(message: "Missing screenshot or coordinates") }
        return CGPoint(x: min(max(x / size.width, 0), 1), y: min(max(y / size.height, 0), 1))
    }

    func execute(_ method: String, _ p: [String: Any], record: (JObject) -> Void) async throws {
        try Task.checkCancellation()
        try await beforeGesture?()
        let target = try (p["target"] as? [String: Any]).map(point)
        func location(_ point: CGPoint) -> JObject { ["x": .num(point.x * 1000), "y": .num(point.y * 1000)] }
        func focus() async throws {
            if let target { try await phone.tap(target.x, target.y, aim: false) }
        }
        switch method {
        case "tap", "longPress":
            let at = try point(p), duration = (p["duration"] as? Double ?? 500) / 1000
            record(location(at).merging(["action": .str(method == "tap" ? "tap" : "longpress"), "duration": .num(duration)]))
            if method == "tap" { try await phone.tap(at.x, at.y, aim: false) }
            else { try await phone.stroke([at], duration: max(0, duration), hold: false) }
        case "input":
            let text = p["text"] as? String ?? "", mode = p["mode"] as? String ?? "replace"
            record((target.map(location) ?? [:]).merging(["action": .str(mode == "clear" ? "clear" : "type"),
                                                        "text": .str(text), "mode": .str(mode)]))
            try await focus()
            if mode != "typeOnly" {
                try await phone.key("cmd+a")
                try await Task.sleep(for: .milliseconds(100))
                try await phone.key("backspace")
            }
            if mode != "clear", !text.isEmpty { try await phone.type(text) }
        case "key":
            let combo = Self.key(p["keyName"] as? String ?? "")
            record((target.map(location) ?? [:]).merging(["action": .str("key"), "combo": .str(combo)]))
            try await focus()
            try await phone.key(combo)
        case "swipe", "draw", "scroll":
            let path: [CGPoint], count: Int
            if method == "scroll" {
                let type = p["scrollType"] as? String ?? "singleAction"
                let directions = ["scrollToBottom": "down", "scrollToTop": "up", "scrollToLeft": "left", "scrollToRight": "right"]
                let direction = directions[type] ?? (p["direction"] as? String ?? "down")
                let vertical = direction == "up" || direction == "down"
                let length = vertical ? size.height : size.width
                guard length > 0 else { throw DeviceError(message: "Missing screenshot size") }
                let distance = type == "singleAction" ? (p["distance"] as? Double ?? length * 0.6) / length : 0.6
                let sign = direction == "down" || direction == "right" ? -1.0 : 1.0
                let start = target ?? CGPoint(x: vertical ? 0.5 : (sign < 0 ? 0.8 : 0.2), y: vertical ? (sign < 0 ? 0.8 : 0.2) : 0.5)
                path = [start, CGPoint(x: min(max(start.x + (vertical ? 0 : sign * distance), 0.02), 0.98),
                                       y: min(max(start.y + (vertical ? sign * distance : 0), 0.02), 0.98))]
                count = type == "singleAction" ? 1 : 5
            } else if method == "draw" {
                guard let pairs = p["points"] as? [[Double]], pairs.count >= 2, pairs.allSatisfy({ $0.count == 2 }) else {
                    throw DeviceError(message: "DrawPath needs at least two points")
                }
                path = try pairs.map { try point(["x": $0[0], "y": $0[1]]) }; count = 1
            } else {
                path = try ["start", "end"].map { try point(p[$0] as? [String: Any] ?? [:]) }; count = 1
            }
            let duration = max(0, (p["duration"] as? Double ?? 300) / 1000)
            var act: JObject = ["action": .str(method == "draw" ? "path" : method), "duration": .num(duration), "repeat": .int(count)]
            if method == "draw" { act["points"] = .arr(path.map { .arr([.num($0.x * 1000), .num($0.y * 1000)]) }) }
            else {
                act = act.merging(["x1": .num(path[0].x * 1000), "y1": .num(path[0].y * 1000),
                                   "x2": .num(path[1].x * 1000), "y2": .num(path[1].y * 1000)])
            }
            record(act)
            for index in 0..<count {
                try Task.checkCancellation()
                if index > 0 { try await beforeGesture?() }
                try await phone.stroke(path, duration: duration, hold: method == "scroll")
                if method == "scroll" { record(["completedRepeat": .int(index + 1)]) }
            }
        case "home", "back":
            record(["action": .str(method)])
            if method == "home" { try await phone.goHome() } else { try await phone.goBack() }
        default: throw DeviceError(message: "Unknown device action: \(method)")
        }
    }

    static func key(_ name: String) -> String {
        let aliases = ["command": "cmd", "meta": "cmd", "control": "ctrl", "option": "alt", "escape": "esc",
                       "return": "enter", "arrowup": "up", "arrowdown": "down", "arrowleft": "left", "arrowright": "right"]
        return name.lowercased().split(separator: "+").map { aliases[String($0)] ?? String($0) }.joined(separator: "+")
    }
}
