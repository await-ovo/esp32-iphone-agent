import XCTest
import UIKit
import UserNotifications
@testable import IPhoneAgent

/// Legacy action parsing remains in use for demonstrations and imported reviews.
@MainActor final class AgentTests: XCTestCase {

    func testParsePathAndCircle() throws {
        XCTAssertEqual(try Actions.parseCommand("path 100 200 300 400 500 600")["points"],
                       .arr([.arr([.int(100), .int(200)]), .arr([.int(300), .int(400)]), .arr([.int(500), .int(600)])]))
        XCTAssertEqual(try Actions.parseCommand("circle 500 450 200"),
                       ["action": .str("circle"), "x": .int(500), "y": .int(450), "r": .int(200)])
    }

    func testParseRejectsBadCommands() {
        for line in ["fly 1 2", "tap 500", "path 1 2 3"] {
            XCTAssertThrowsError(try Actions.parseCommand(line), line)
        }
    }

    func testCircleIsClosedAndRoundOnATallScreen() {
        let aspect = 0.46  // width / height of a portrait iPhone frame
        let pts = circle(0.5, 0.5, 0.2, aspect: aspect)
        XCTAssertEqual(pts[0].x, pts.last!.x, accuracy: 1e-9)
        XCTAssertEqual(pts[0].y, pts.last!.y, accuracy: 1e-9)
        for p in pts {  // equal radius in pixels: y offsets shrink by the aspect ratio
            XCTAssertEqual(hypot(p.x - 0.5, (p.y - 0.5) / aspect), 0.2, accuracy: 1e-9)
        }
    }

    func testPreciseTapFlag() throws {
        XCTAssertEqual(try Actions.parseCommand("tap 120 640 precise"),
                       ["action": .str("tap"), "x": .int(120), "y": .int(640), "precise": .bool(true)])
        XCTAssertNil(try Actions.parseCommand("tap 120 640")["precise"])
    }

}

// MARK: - fakes

@MainActor final class FakeScreen: ScreenSource {
    var live = true
    var frame: Data? = Data([0xff, 0xd8])
    var updated = 0.0
    var capturedAt = 0.0
    var aspect = 0.46
}

@MainActor final class FakeDevice: HIDDevice {
    var links = 1
    var connected = true
    var sent: [String] = []
    func send(_ command: String) async throws -> String { sent.append(command); return "" }
    func waitConnected(_ timeout: TimeInterval) async -> Bool { connected }
}

@MainActor final class FakeGestures: Gestures {
    let device: HIDDevice = FakeDevice()
    var calls: [String] = []
    func tap(_ x: Double, _ y: Double, aim: Bool) async throws { calls.append("tap") }
    func swipe(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, hold: Bool) async throws { calls.append("swipe") }
    func stroke(_ points: [CGPoint], duration: Double, hold: Bool) async throws { calls.append("stroke") }
    func drag(_ points: [CGPoint], hold: Bool) async throws { calls.append("drag") }
    func type(_ text: String) async throws { calls.append("type " + text) }
    func key(_ combo: String) async throws { calls.append("key " + combo) }
    func goHome() async throws { calls.append("home") }
    func goBack() async throws { calls.append("back") }
    func reset() async throws { calls.append("reset") }
}

@MainActor final class MidsceneTests: XCTestCase {
    private func image() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 200, height: 400), format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 400))
        }
    }

    func testPixelsBecomePointerFractionsAndReviewCoordinates() async throws {
        let phone = FakeGestures()
        let device = MidsceneDevice(phone: phone)
        _ = try device.capture(image())
        XCTAssertEqual(device.size, CGSize(width: 200, height: 400))
        XCTAssertEqual(try device.point(["x": 100.0, "y": 100.0]), CGPoint(x: 0.5, y: 0.25))
        var record = JObject()
        try await device.execute("tap", ["x": 100.0, "y": 100.0]) { record = record.merging($0) }
        XCTAssertEqual(record["x"]?.double, 500)
        XCTAssertEqual(record["y"]?.double, 250)
        XCTAssertEqual(phone.calls, ["tap"])
    }

    func testInputFocusClearAndTypeHaveNoExtraChecks() async throws {
        let phone = FakeGestures()
        let device = MidsceneDevice(phone: phone)
        let input = device
        _ = try input.capture(image())
        try await input.execute("input", ["text": "hello", "mode": "replace", "target": ["x": 80.0, "y": 100.0]]) { _ in }
        XCTAssertEqual(phone.calls, ["tap", "key cmd+a", "key backspace", "type hello"])
        phone.calls = []
        try await input.execute("input", ["text": "", "mode": "clear"]) { _ in }
        XCTAssertEqual(phone.calls, ["key cmd+a", "key backspace"])
        phone.calls = []
        try await input.execute("input", ["text": "hello", "mode": "typeOnly"]) { _ in }
        XCTAssertEqual(phone.calls, ["type hello"])
    }

    func testKeyboardAliasesAndScrollDirection() async throws {
        XCTAssertEqual(MidsceneDevice.key("Command+ArrowLeft"), "cmd+left")
        XCTAssertEqual(MidsceneDevice.key("Control+A"), "ctrl+a")
        let phone = FakeGestures()
        let device = MidsceneDevice(phone: phone)
        _ = try device.capture(image())
        var record = JObject()
        try await device.execute("scroll", ["direction": "down", "distance": 120.0]) { record = record.merging($0) }
        XCTAssertGreaterThan(record["y1"]!.double!, record["y2"]!.double!)
        XCTAssertEqual(record["y1"]!.double! - record["y2"]!.double!, 300, accuracy: 0.001)
        XCTAssertEqual(phone.calls, ["stroke"])
    }

    func testCancellationStopsBeforeNativeInput() async {
        let phone = FakeGestures()
        let device = MidsceneDevice(phone: phone)
        let job = Task { try await device.execute("home", [:]) { _ in } }
        job.cancel()
        do { try await job.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(phone.calls.isEmpty)
    }

    func testRepeatedScrollHonorsGateBetweenStrokes() async throws {
        let phone = FakeGestures()
        let scroll = MidsceneDevice(phone: phone)
        _ = try scroll.capture(image())
        var checks = 0
        scroll.beforeGesture = {
            checks += 1
            if checks == 2 { throw CancellationError() }
        }
        do { try await scroll.execute("scroll", ["scrollType": "scrollToBottom"]) { _ in }; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(phone.calls, ["stroke"])
    }

    func testContinuationIncludesCompletedAndUncertainActionsWithoutImages() {
        let agent = MidsceneController(phone: nil, screen: nil, trace: nil)
        agent.showMock(task: "Send hello then go Home", plan: "", steps: [
            ["sdkAction": .str("Input"), "action": .str("type"), "text": .str("hello"), "status": .str("completed"), "frame": .str("private.jpg")],
            ["sdkAction": .str("Home"), "action": .str("home"), "status": .str("failed"), "reason": .str("timeout")],
            ["sdkAction": .str("Tap"), "action": .str("tap"), "status": .str("completed"), "thought": .str("Tapped Send")],
        ], running: false)
        let prompt = agent.continuationPrompt(note: "Continue", reason: "timeout")
        XCTAssertTrue(prompt.contains("hello"))
        XCTAssertTrue(prompt.contains("Tapped Send"))
        XCTAssertTrue(prompt.contains("completed"))
        XCTAssertTrue(prompt.contains("failed"))
        XCTAssertTrue(prompt.contains("Do not repeat completed effects"))
        XCTAssertFalse(prompt.contains("private.jpg"))
    }

    func testLightTraceUpdatesOneCardAndDeduplicatesScreenshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = TraceStore(root: root)
        trace.start(task: "Clear a field")
        let frame = try XCTUnwrap(trace.saveFrame(image()))
        XCTAssertEqual(trace.saveFrame(image()), frame)
        trace.write(kind: "step", ["id": .int(0), "traceVersion": .int(2), "frame": .str(frame), "action": .str("clear"), "status": .str("running")])
        trace.write(kind: "step-update", ["id": .int(0), "status": .str("failed"), "reason": .str("board disconnected")])
        trace.write(kind: "step", ["id": .int(1), "traceVersion": .int(2), "action": .str("stopped")])
        let folder = try XCTUnwrap(trace.dir), run = try XCTUnwrap(RunStore.load(folder))
        XCTAssertEqual(run.steps.count, 2)
        XCTAssertEqual(run.steps[0].action["status"]?.str, "failed")
        XCTAssertEqual(run.steps[0].frame?.lastPathComponent, frame)
        XCTAssertNil(run.steps[1].frame, "new traces do not inherit an unrelated previous frame")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".jpg") }.count, 1)
        XCTAssertFalse(files.contains { $0.hasSuffix(".html") || $0 == "video" })
    }

    func testPublishedSDKRunsTwoActionsThroughWKWebViewAndStreamingHTTP() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MidsceneModelFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let runtime = MidsceneRuntime(session: session)
        defer { runtime.close() }
        let screenshot = "data:image/jpeg;base64," + image().base64EncodedString()
        var homes = 0, phases: [String] = [], commands: [String] = []
        var input: [String: Any] = [:], usage: [String: Any] = [:]
        runtime.handle = { method, params in
            commands.append(method)
            switch method {
            case "screenshot": return screenshot
            case "size": return ["width": 200, "height": 400]
            case "home": homes += 1
            case "input": input = params
            case "usage": usage = params
            case "progress": phases.append(params["phase"] as? String ?? "")
            default: break
            }
            return NSNull()
        }
        MidsceneModelFixture.calls = 0
        MidsceneModelFixture.prompts = []
        try await runtime.prepare()
        let result = try await runtime.run(["baseURL": "https://midscene-fixture.invalid/v1", "model": "gpt-5",
                                           "family": "gpt-5", "apiKey": "fixture", "extra": [:], "maxSteps": 4,
                                           "prompt": "Go Home, type hello in the focused field, then complete.\n\nHints for this task:\n- Keep the existing recipient."])
        XCTAssertEqual(result["ok"] as? Bool, true, String(describing: result))
        XCTAssertEqual(homes, 1)
        XCTAssertEqual(input["text"] as? String, "hello")
        XCTAssertEqual(input["mode"] as? String, "typeOnly")
        XCTAssertEqual(usage["tokens"] as? Int, 12)
        XCTAssertEqual(commands.filter { $0 == "actionBegin" }.count, 2)
        XCTAssertEqual(commands.filter { $0 == "actionEnd" }.count, 2)
        XCTAssertTrue(phases.contains("action_running"))
        XCTAssertTrue(phases.contains("complete"))
        XCTAssertEqual(MidsceneModelFixture.prompts.count, 3)
        for prompt in MidsceneModelFixture.prompts {
            XCTAssertTrue(prompt.contains("<CONTEXT>"), "Use the SDK context API in every planning cycle")
            XCTAssertTrue(prompt.contains("1. 设备与输入限制"))
            XCTAssertTrue(prompt.contains("优先调用 Home 动作，无需自行模拟底部上滑"))
            XCTAssertTrue(prompt.contains("屏幕键盘不一定显示"))
            XCTAssertTrue(prompt.contains("8. 检查结果和处理不确定性"))
            XCTAssertTrue(prompt.contains("Go Home, type hello"), "Keep the task alongside the context")
            XCTAssertTrue(prompt.contains("Keep the existing recipient."), "Keep saved-task hints alongside the context")
        }
    }

    func testRuntimeStopRejectsPendingWork() async throws {
        let runtime = MidsceneRuntime()
        defer { runtime.close() }
        runtime.handle = { _, _ in try await Task.sleep(for: .seconds(30)); return NSNull() }
        try await runtime.prepare()
        let job = Task { try await runtime.run(["baseURL": "https://example.invalid/v1", "model": "gpt-5", "family": "gpt-5",
                                               "apiKey": "fixture", "extra": [:], "maxSteps": 2, "prompt": "Go Home"]) }
        try await Task.sleep(for: .milliseconds(200))
        runtime.stop()
        do { _ = try await job.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

private final class MidsceneModelFixture: URLProtocol {
    static var calls = 0
    static var prompts: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "midscene-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let messages = json["messages"] as? [[String: Any]] ?? []
        let data = (try? JSONSerialization.data(withJSONObject: messages)) ?? Data()
        Self.prompts.append(String(decoding: data, as: UTF8.self))
        let content: String
        switch Self.calls {
        case 1: content = "<planning>Go Home.</planning><action-type>Home</action-type><action-param-json>{}</action-param-json>"
        case 2: content = #"<planning>Type hello.</planning><action-type>Input</action-type><action-param-json>{"value":"hello","mode":"typeOnly"}</action-param-json>"#
        default: content = "<complete success=\"true\">Finished</complete>"
        }
        let chunk: [String: Any] = ["id": "fixture", "object": "chat.completion.chunk", "model": "gpt-5",
                                   "usage": ["prompt_tokens": 10, "completion_tokens": 2, "total_tokens": 12],
                                   "choices": [["index": 0, "delta": ["role": "assistant", "content": content], "finish_reason": "stop"]]]
        let text = "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: chunk), as: UTF8.self)
            + "\n\ndata: [DONE]\n\n"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class NotificationTests: XCTestCase {
    func testNotificationActionAndUIKitCompletionBothReturnToTheMainThread() async {
        let center = UNUserNotificationCenter.current(), previous = UNUserNotificationCenter.current().delegate
        defer { center.delegate = previous }
        let notifier = Notifier()
        let completed = expectation(description: "Notification completion")
        var received = false
        notifier.onAction = { action, run in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(action, .stop)
            XCTAssertEqual(run, "fixture-run")
            received = true
        }
        await Task.detached {
            notifier.deliver(.stop, run: "fixture-run") {
                XCTAssertTrue(Thread.isMainThread)
                completed.fulfill()
            }
        }.value
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertTrue(received)
    }
}
