import Foundation
import CryptoKit

/// One local folder per run: compact step events, deduplicated JPEGs and metrics.
/// Documents is shared with Finder/devicectl; full Midscene reports are not generated.
@MainActor final class TraceStore {
    let root: URL
    private(set) var dir: URL?
    private var n = 0
    private var frames = Set<String>()

    init(root: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("traces")) {
        self.root = root
    }

    func start(task: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        var d = root.appendingPathComponent(f.string(from: Date()))
        if FileManager.default.fileExists(atPath: d.path) { d.appendPathExtension(String(UUID().uuidString.prefix(8))) }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dir = d
        n = 0
        frames = []
        write(kind: "task", ["task": .str(task)])
    }

    /// Repeated SDK screenshots share one JPEG; JSON records reference the file, never base64.
    func saveFrame(_ frame: Data) -> String? {
        guard let dir else { return nil }
        let name = SHA256.hash(data: frame).map { String(format: "%02x", $0) }.joined() + ".jpg"
        if frames.contains(name) { return name }
        do { try frame.write(to: dir.appendingPathComponent(name)); frames.insert(name); return name }
        catch { DebugLog.write("trace screenshot: \(error.localizedDescription)"); return nil }
    }

    func write(_ frame: Data? = nil, kind: String, _ record: JObject) {
        guard let dir else { return }
        n += 1
        var line = JObject([("n", .int(n)), ("t", .num(now())), ("kind", .str(kind))]).merging(record)
        if let frame {
            let name = String(format: "%03d.jpg", n)
            line["frame"] = .str(name)
            try? frame.write(to: dir.appendingPathComponent(name))
        }
        append(PyJSON.dumps(line, ascii: false) + "\n", to: dir.appendingPathComponent("steps.jsonl"))
    }

    func writeMetrics(_ metrics: [String: Any]) {
        guard let dir, JSONSerialization.isValidJSONObject(metrics),
              let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: dir.appendingPathComponent("metrics.json"))
    }

    func runs() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return items.filter(\.hasDirectoryPath).sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// All traces zipped (via a coordinated read "for uploading"), for the share sheet.
    nonisolated static func zip(_ folder: URL, name: String = "traces.zip") throws -> URL {
        var result: URL?, failure: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordError) { tmp in
            let out = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: out)
            do { try FileManager.default.copyItem(at: tmp, to: out); result = out } catch { failure = error }
        }
        if let e = coordError ?? failure { throw e }
        guard let result else { throw DeviceError(message: "zip failed") }
        return result
    }

    private func append(_ text: String, to url: URL) {
        let data = Data(text.utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
