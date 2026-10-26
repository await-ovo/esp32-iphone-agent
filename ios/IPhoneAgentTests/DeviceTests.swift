import XCTest
@testable import IPhoneAgent

/// A board that answers every command like the firmware does.
@MainActor final class FakeBoard: BoardTransport {
    var isConnected = true
    var lines: [String] = []
    var drops = 0
    var silent = false
    var failNext: Error?
    weak var channel: CommandChannel?

    func write(_ line: String) throws {
        lines.append(line)
        if let error = failNext { failNext = nil; throw error }
        guard !silent else { return }
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let reply = parts[1] == "bad" ? "\(parts[0]) err unknown command" : "\(parts[0]) ok"
        Task { @MainActor in self.channel?.handleReply(reply) }
    }

    func dropLink() { drops += 1 }
}

/// Port of server/tests/test_device.py, with a fake BLE transport instead of a TCP socket.
@MainActor final class DeviceTests: XCTestCase {
    func testUnacknowledgedClickIsNotReplayed() async {
        let board = FakeBoard(), channel = CommandChannel()
        channel.transport = board; board.channel = channel
        board.failNext = DeviceError(message: "timeout")
        var recovered = false
        channel.onTimeout = { _ in recovered = true }
        do { try await channel.send("click"); XCTFail("Expected uncertain execution") }
        catch { XCTAssertTrue(error.localizedDescription.contains("execution is uncertain")) }
        XCTAssertTrue(recovered)
        XCTAssertEqual(board.lines.count, 1)
    }

    func testCancellingLongPressReleasesThePointer() async throws {
        let board = FakeBoard(), channel = CommandChannel()
        channel.transport = board; board.channel = channel
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: channel, calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        let job = Task { try await pointer.stroke([CGPoint(x: 0.5, y: 0.5)], duration: 30, hold: false) }
        for _ in 0..<100 {
            if board.lines.contains(where: { $0.hasSuffix(" press") }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(board.lines.contains { $0.hasSuffix(" press") })
        job.cancel()
        do { try await job.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(board.lines.last?.hasSuffix(" release") == true)
    }

    func testTimeoutGrowsWithMoveDistanceAndTextLength() {
        XCTAssertEqual(CommandChannel.timeout("click"), 5)
        XCTAssertGreaterThan(CommandChannel.timeout("move 1000 -20"), CommandChannel.timeout("move 10 10"))
        XCTAssertGreaterThanOrEqual(CommandChannel.timeout("move 10 10"), 5)
        XCTAssertEqual(CommandChannel.timeout("scroll 1000 -20"), CommandChannel.timeout("move 1000 -20"))
        XCTAssertGreaterThan(CommandChannel.timeout("type " + String(repeating: "x", count: 40)),
                             CommandChannel.timeout("type hi"))
    }

    func testSendWithoutBoardFailsFast() async {
        do {
            try await CommandChannel().send("ping")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not connected"))
        }
    }

    func testRoundTripWithAFakeBoard() async throws {
        let board = FakeBoard()
        let channel = CommandChannel(transport: board)
        board.channel = channel
        channel.linkUp()
        let ok = await channel.waitConnected(2)
        XCTAssertTrue(ok)
        try await channel.send("ping")
        do {
            try await channel.send("bad")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unknown command"))
        }
        XCTAssertEqual(channel.links, 1)
        let ids = board.lines.compactMap { Int($0.split(separator: " ")[0]) }  // request ids: random start, then +1
        XCTAssertEqual(board.lines.map { $0.split(separator: " ")[1] }, ["ping", "bad"])
        XCTAssertEqual(ids.count == 2 ? ids[1] - ids[0] : 0, 1)
    }

    func testCommandsGoOneAtATime() async throws {
        let board = FakeBoard()
        let channel = CommandChannel(transport: board)
        board.channel = channel
        async let a: String = channel.send("move 1 0")
        async let b: String = channel.send("move -1 0")
        _ = try await (a, b)
        XCTAssertEqual(board.lines.count, 2)
    }

    func testLinkDownFailsCommandsInFlight() async {
        let board = FakeBoard()
        board.silent = true
        let channel = CommandChannel(transport: board)
        board.channel = channel
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            channel.linkDown()
        }
        do {
            try await channel.send("click")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("disconnected"))
        }
    }

    func testReplyParsing() {
        XCTAssertEqual(BoardReply.parse("12 ok"), BoardReply(id: 12, ok: true, text: ""))
        XCTAssertEqual(BoardReply.parse("3 ok 812\n"), BoardReply(id: 3, ok: true, text: "812"))
        XCTAssertEqual(BoardReply.parse("4 err unknown command"), BoardReply(id: 4, ok: false, text: "unknown command"))
        XCTAssertNil(BoardReply.parse("ok"))
    }

    func testStatusDecoding() throws {
        let json = #"{"up":123456,"rst":"power-on","heap":81234,"hid":"ok","ble":{"mtu":247,"phy":2}}"#
        let s = try XCTUnwrap(BoardStatus.decode(Data(json.utf8)))
        XCTAssertEqual(s.heap, 81234)
        XCTAssertEqual(s.ble?.mtu, 247)
        XCTAssertTrue(s.inputReady)
    }

    func testPositioningUsesTheCalibratedPathInsteadOfRememberingTheLastTarget() async throws {
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let pointer = Pointer(device: device, calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)  // span 400 x 800
        defer { try? FileManager.default.removeItem(at: file) }
        try await pointer.point(0.5, 0.5)
        try await pointer.point(0.5, 0.5)
        try await pointer.point(0.2, 0.1)
        XCTAssertEqual(device.sent, ["release", "home", "move 200 0", "move 0 400",
                                    "home", "move 200 0", "move 0 400",
                                    "home", "move 80 0", "move 0 80"])
    }

    func testHeldGestureKeepsItsDiagonalPathAfterPositioning() async throws {
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: device, calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        try await pointer.stroke([CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.75)], duration: 0)
        XCTAssertEqual(device.sent, ["release", "home", "move 100 0", "move 0 200", "press", "move 200 400", "release"])
    }

    func testCancelledPositioningCannotClick() async throws {
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: device, calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        let task = Task { try await pointer.tap(0.5, 0.5) }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(device.sent.contains("click"))
    }

    func testShortStatusNotifyIsMergedWithTheFullRead() throws {
        let full = try XCTUnwrap(BoardStatus.decode(Data(#"{"up":1,"heap":81234,"hid":"ok","ble":{"mtu":247,"phy":2}}"#.utf8)))
        let short = try XCTUnwrap(BoardStatus.decode(Data(#"{"up":2,"hid":"asleep","ble":{"mtu":23}}"#.utf8)))
        let m = full.merged(with: short)
        XCTAssertEqual(m.up, 2)
        XCTAssertEqual(m.hid, "asleep")
        XCTAssertEqual(m.heap, 81234)  // kept from the full read
        XCTAssertEqual(m.ble?.mtu, 23)
        XCTAssertEqual(m.ble?.phy, 2)
    }

    func testFreshCalibrationHasNoDriftAndSurvivesARestart() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let pointer = Pointer(device: FakeDevice(), calibrationFile: file)
        XCTAssertFalse(pointer.calibrated)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        XCTAssertEqual(pointer.drift, 0)
        pointer.setQuality(0.006)  // only independently verified calibrations survive a restart
        let again = Pointer(device: FakeDevice(), calibrationFile: file)
        XCTAssertEqual(again.span, Pointer.Span(w: 400, h: 800))
    }

    func testBLEHIDReadinessOverridesUSBAndSurvivesShortStatus() throws {
        let full = try XCTUnwrap(BoardStatus.decode(Data(#"{"up":1,"hid":"off","hgen":2}"#.utf8)))
        XCTAssertFalse(full.inputReady, "a USB cable does not make the BLE mouse ready")
        let short = try XCTUnwrap(BoardStatus.decode(Data(#"{"up":2,"hid":"ok","hgen":3}"#.utf8)))
        let merged = full.merged(with: short)
        XCTAssertTrue(merged.inputReady)
        XCTAssertEqual(merged.hgen, 3)
        let heartbeat = try XCTUnwrap(BoardStatus.decode(Data(#"{"up":3}"#.utf8)))
        XCTAssertTrue(merged.merged(with: heartbeat).inputReady)
        let legacy = try XCTUnwrap(BoardStatus.decode(Data(#"{"hid":"ok"}"#.utf8)))
        XCTAssertTrue(legacy.inputReady)
        XCTAssertTrue(full.merged(with: legacy).inputReady)
    }

    func testChangingHIDTransportInvalidatesCalibrationButRestartDoesNot() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: FakeDevice(), calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        pointer.useTransport("ble")
        XCTAssertFalse(pointer.calibrated)
        pointer.finishCalibration(x: 0.4, y: 0.2)
        pointer.setQuality(0.006)
        let again = Pointer(device: FakeDevice(), calibrationFile: file)
        again.useTransport("ble")
        XCTAssertEqual(again.span, pointer.span)
        again.useTransport("usb")
        XCTAssertFalse(again.calibrated)
    }

    func testOldDiagonalCalibrationAndUnverifiedCandidateAreNotRestored() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"w":465,"h":1224,"quality":0.005,"transport":"ble"}"#.utf8).write(to: file)
        XCTAssertFalse(Pointer(device: FakeDevice(), calibrationFile: file).calibrated)
        let candidate = Pointer(device: FakeDevice(), calibrationFile: file)
        candidate.finishCalibration(x: 0.5, y: 0.25)
        XCTAssertTrue(candidate.calibrated)
        XCTAssertFalse(Pointer(device: FakeDevice(), calibrationFile: file).calibrated)
        candidate.setQuality(0.006)
        XCTAssertTrue(Pointer(device: FakeDevice(), calibrationFile: file).calibrated)
        candidate.setQuality(0.04)
        XCTAssertFalse(candidate.calibrated)
        XCTAssertFalse(Pointer(device: FakeDevice(), calibrationFile: file).calibrated)
    }

    func testModelSettingsNeedOnlyAnEndpoint() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = Settings(defaults: defaults, info: nil, credentialNamespace: "test-" + UUID().uuidString)  // no build-time preset
        XCTAssertFalse(settings.isConfigured)  // nothing is built in
        settings.baseURL = "https://example.com/v1"
        XCTAssertTrue(settings.isConfigured)  // the model is picked from GET /models
        XCTAssertNil(settings.currentModel)
        settings.model = "some-model"
        XCTAssertEqual(settings.currentModel, "some-model")
    }

    func testProbeFitRecoversScaleAndOffset() {
        let samples: [(Double, Double)] = [150.0, 350, 60].map { u in (u, 0.02 + u / 400) }
        let line = ProbeFit.line(samples)
        XCTAssertEqual(line?.a ?? 0, 1 / 400, accuracy: 1e-9)
        XCTAssertEqual(line?.b ?? 0, 0.02, accuracy: 1e-9)
        XCTAssertEqual(line?.rms ?? 1, 0, accuracy: 1e-9)
        XCTAssertEqual(line?.units(for: 0.52), 200)
        XCTAssertNil(ProbeFit.line([(100, 0.3)]))
        XCTAssertFalse(ProbeFit.usable(0.995))  // stuck at the edge
    }
}
