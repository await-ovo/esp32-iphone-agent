import Foundation

/// Action notation used by demonstrations, review editing, and legacy traces.
enum Actions {
    struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Bookkeeping keys that are not part of the action itself.
    static let meta: Set<String> = ["t", "thought", "thought_zh", "think_s", "act_s", "shot", "_shot", "changed",
                                    "id", "traceVersion", "frame", "sdkAction", "status", "frameWidth", "frameHeight"]

    /// action name -> argument names; numeric arguments are 0-1000 screen coordinates
    static let actions: [String: [String]] = [
        "tap": ["x", "y"], "swipe": ["x1", "y1", "x2", "y2"], "circle": ["x", "y", "r"], "path": ["points"],
        "type": ["text"], "key": ["combo"], "done": ["answer"], "fail": ["reason"],
        "home": [], "back": [], "wait": [], "replan": [],
    ]
    static let textArgs: Set<String> = ["text", "combo", "answer", "reason"]

    /// One DO line, e.g. "tap 152 362" -> {"action": "tap", "x": 152, "y": 362}.
    static func parseCommand(_ line: String) throws -> JObject {
        let (head, rest) = partition(line.trimmingCharacters(in: .whitespacesAndNewlines))
        let name = head.lowercased()
        guard let keys = actions[name] else { throw ParseError(message: "unknown action: \(line.prefix(100))") }
        if let first = keys.first, textArgs.contains(first) {
            let text = rest.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return ["action": .str(name), first: .str(text)]
        }
        let numbers = matches(#"-?\d+(?:\.\d+)?"#, in: rest).compactMap { Double($0) }.map { Int($0) }
        if keys == ["points"] {
            guard numbers.count >= 4, numbers.count % 2 == 0 else {
                throw ParseError(message: "path needs 2+ x y pairs: \(line.prefix(100))")
            }
            let points = stride(from: 0, to: numbers.count, by: 2).prefix(20)
                .map { JValue.arr([.int(numbers[$0]), .int(numbers[$0 + 1])]) }
            return ["action": .str(name), "points": .arr(Array(points))]
        }
        guard numbers.count == keys.count else {
            throw ParseError(message: "\(name) needs \(keys.count) numbers: \(line.prefix(100))")
        }
        var action: JObject = ["action": .str(name)]
        for (k, n) in zip(keys, numbers) { action[k] = .int(n) }
        if name == "tap" && rest.lowercased().contains("precise") { action["precise"] = .bool(true) }
        return action
    }

    /// The action itself, without thoughts, timings and other bookkeeping.
    static func key(_ step: JObject) -> JObject { step.without(meta) }

    // MARK: - helpers

    private static func partition(_ s: String) -> (String, String) {
        guard let i = s.firstIndex(of: " ") else { return (s, "") }
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }

    private static func regex(_ p: String, multiline: Bool) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: multiline ? [.anchorsMatchLines, .caseInsensitive] : [])
    }

    private static func matches(_ p: String, in s: String) -> [String] {
        let ns = s as NSString
        return regex(p, multiline: false).matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }


}

/// The [[x, y], …] points of a path action, in 0-1000 units.
func points(_ act: JObject) -> [CGPoint] {
    guard case .arr(let items)? = act["points"] else { return [] }
    return items.compactMap {
        guard case .arr(let p) = $0, p.count == 2, let x = p[0].double, let y = p[1].double else { return nil }
        return CGPoint(x: x, y: y)
    }
}

/// Points around a circle; r is a fraction of the width, aspect = width / height.
func circle(_ x: Double, _ y: Double, _ r: Double, aspect: Double, n: Int = 24) -> [CGPoint] {
    (0...n).map { i in
        let a = 2 * Double.pi * Double(i) / Double(n)
        return CGPoint(x: x + r * cos(a), y: y + r * aspect * sin(a))
    }
}
