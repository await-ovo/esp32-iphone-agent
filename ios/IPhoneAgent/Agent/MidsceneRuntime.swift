import WebKit
import SwiftUI

/// One WebContent process lifetime per run. Only local bundled code can call the native bridge.
@MainActor final class MidsceneRuntime: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    let webView: WKWebView
    private let session: URLSession
    var handle: ((String, [String: Any]) async throws -> Any)?
    private var ready = false
    private var failure: Error?
    private var active = true
    private var result: CheckedContinuation<[String: Any], Error>?
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var bodies: [String: HTTPBody] = [:]
    private var secret = ""
    private var tokenParam = "auto"

    init(session: URLSession = .shared) {
        self.session = session
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.inactiveSchedulingPolicy = .none
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "native")
        webView.navigationDelegate = self
        #if DEBUG
        webView.isInspectable = true
        #endif
    }

    func prepare() async throws {
        guard let file = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Midscene") else {
            throw DeviceError(message: "Midscene bundle missing. Run pnpm build in ios/Midscene before building the app.")
        }
        webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        let deadline = now() + 20
        while !ready {
            try Task.checkCancellation()
            if let failure { throw failure }
            guard active, now() < deadline else { throw DeviceError(message: "Midscene runtime did not start") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func run(_ config: [String: Any]) async throws -> [String: Any] {
        guard active, ready else { throw DeviceError(message: "Midscene runtime is not ready") }
        secret = config["apiKey"] as? String ?? ""
        tokenParam = config["tokenParam"] as? String ?? "auto"
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                result = continuation
                webView.callAsyncJavaScript("void window.Midscene.run(config);", arguments: ["config": config],
                                           in: nil, in: .page) { [weak self] outcome in
                    if case .failure(let error) = outcome { self?.finish(.failure(error)) }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.stop() } }
    }

    func stop() {
        guard active else { return }
        active = false  // block native side effects even if WebKit cannot receive abort yet
        webView.evaluateJavaScript("window.Midscene?.stop()", completionHandler: nil)
        requests.values.forEach { $0.cancel() }
        bodies.values.forEach { $0.cancel() }
        bodies.removeAll()
        finish(.failure(CancellationError()))
    }

    func close() {
        stop()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "native", contentWorld: .page)
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
        webView.loadHTMLString("", baseURL: nil)
        handle = nil
        secret = ""
    }

    private func finish(_ outcome: Result<[String: Any], Error>) {
        let continuation = result
        result = nil
        continuation?.resume(with: outcome)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, active, let body = message.body as? [String: Any],
              let method = body["method"] as? String else {
            replyHandler(["ok": false, "error": "Runtime closed or invalid message"], nil); return
        }
        let params = body["params"] as? [String: Any] ?? [:]
        let id = ["httpStart", "httpRead"].contains(method)
            ? (pID(params) ?? UUID()) : UUID()
        requests[id] = Task { [weak self] in
            guard let self else { replyHandler(nil, "Runtime closed"); return }
            defer { requests[id] = nil }
            do {
                try Task.checkCancellation()
                let value = try await receive(method, params)
                try Task.checkCancellation()
                replyHandler(["ok": true, "value": value], nil)
            } catch {
                let text = secret.isEmpty ? error.localizedDescription
                    : error.localizedDescription.replacingOccurrences(of: secret, with: "[redacted]")
                replyHandler(["ok": false, "error": text], nil)
            }
        }
    }

    private func pID(_ p: [String: Any]) -> UUID? { (p["id"] as? String).flatMap(UUID.init(uuidString:)) }

    private func receive(_ method: String, _ p: [String: Any]) async throws -> Any {
        switch method {
        case "ready": ready = true
        case "fatal":
            failure = DeviceError(message: p["error"] as? String ?? "Midscene initialization failed")
            finish(.failure(failure!))
        case "finished": finish(.success(p))
        case "httpStart":
            guard let id = p["id"] as? String, let text = p["url"] as? String,
                  let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
                throw DeviceError(message: "Invalid model URL")
            }
            var request = URLRequest(url: url, timeoutInterval: 120)
            request.httpMethod = p["method"] as? String ?? "POST"
            request.httpBody = (p["body"] as? String)?.data(using: .utf8)
            if tokenParam != "auto", let data = request.httpBody,
               var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let tokens = json.removeValue(forKey: "max_tokens") {
                json[tokenParam] = json[tokenParam] ?? tokens
                request.httpBody = try JSONSerialization.data(withJSONObject: json)
            }
            request.allHTTPHeaderFields = p["headers"] as? [String: String]
            let (bytes, response) = try await session.bytes(for: request)
            guard active, !Task.isCancelled else { bytes.task.cancel(); throw CancellationError() }
            guard let http = response as? HTTPURLResponse else { bytes.task.cancel(); throw DeviceError(message: "Invalid HTTP response") }
            bodies[id] = HTTPBody(bytes)
            return ["status": http.statusCode, "headers": http.allHeaderFields.reduce(into: [String: String]()) {
                $0[String(describing: $1.key)] = String(describing: $1.value)
            }]
        case "httpRead":
            guard let id = p["id"] as? String, let body = bodies[id] else { throw CancellationError() }
            do {
                if let bytes = try await body.read() { return bytes.base64EncodedString() }
                bodies[id] = nil
            } catch { body.cancel(); bodies[id] = nil; throw error }
        case "httpCancel":
            if let id = pID(p) { requests[id]?.cancel() }
            if let id = p["id"] as? String { bodies.removeValue(forKey: id)?.cancel() }
        default:
            guard let handle else { throw DeviceError(message: "Device bridge is unavailable") }
            return try await handle(method, p)
        }
        return NSNull()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failure = DeviceError(message: "WebContent terminated; this task was interrupted")
        finish(.failure(failure!))
        stop()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failure = error
        finish(.failure(error))
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
}

/// The JS stream makes one read at a time; each SSE line is delivered as soon as it arrives.
@MainActor private final class HTTPBody {
    private var iterator: URLSession.AsyncBytes.Iterator
    private let task: URLSessionTask
    init(_ bytes: URLSession.AsyncBytes) { iterator = bytes.makeAsyncIterator(); task = bytes.task }
    func cancel() { task.cancel() }
    func read() async throws -> Data? {
        var data = Data()
        var iterator = self.iterator
        defer { self.iterator = iterator }
        while let byte = try await iterator.next() {
            try Task.checkCancellation()
            data.append(byte)
            if byte == 10 || data.count >= 4096 { break }
        }
        return data.isEmpty ? nil : data
    }
}

struct MidsceneHost: UIViewRepresentable {
    @ObservedObject var agent: MidsceneController
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        guard let webView = agent.runtime?.webView, webView.superview !== view else { return }
        view.addSubview(webView)
        webView.frame = view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }
}
