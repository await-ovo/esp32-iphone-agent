import XCTest
@testable import IPhoneAgent

@MainActor final class RecoveryTests: XCTestCase {
    private func link(_ connected: Bool = true, sharing: Bool = true, frameAt: Double = 0) -> Recovery.Link {
        Recovery.Link(connected: connected, frameAt: frameAt, sharing: sharing)
    }

    func testStagesAfterABoardReboot() {
        var r = Recovery(at: 100)
        XCTAssertEqual(r.next(link(false), at: 100), .wait(.init(part: .board, ask: false)))
        XCTAssertEqual(r.next(link(sharing: false), at: 107), .wait(.init(part: .screen, ask: false)))
        XCTAssertEqual(r.next(link(sharing: false), at: 133), .wait(.init(part: .screen, ask: true)))
        XCTAssertEqual(r.next(link(frameAt: 99), at: 140), .wait(.init(part: .screen, ask: true)),
                       "streaming, but no frame newer than the loss yet")
        XCTAssertEqual(r.next(link(frameAt: 141), at: 141), .live)
    }

    func testScreenLossAsksForPermissionRatherThanReconnectingTheBoard() {
        var r = Recovery(at: 0)
        XCTAssertEqual(r.next(link(sharing: false), at: 0), .wait(.init(part: .screen, ask: false)))
        XCTAssertEqual(r.next(link(sharing: false), at: 2), .wait(.init(part: .screen, ask: true)))
        XCTAssertEqual(r.next(link(frameAt: 3), at: 3), .live)
    }

    func testGivesUpAfterFiveMinutesNamingWhatIsMissing() {
        var r = Recovery(at: 0)
        XCTAssertEqual(r.next(link(sharing: false), at: 0), .wait(.init(part: .screen, ask: false)))
        XCTAssertEqual(r.next(link(sharing: false), at: 299), .wait(.init(part: .screen, ask: true)))
        guard case .giveUp(let reason) = r.next(link(sharing: false), at: 300) else { return XCTFail() }
        XCTAssertTrue(reason.contains("Screen sharing"))
    }

    func testTheStatusLabelsSayWhatIsMissing() {
        XCTAssertEqual(Recovery.Stage(part: .board, ask: false).status.full, "Waiting for the board…")
        XCTAssertEqual(Recovery.Stage(part: .screen, ask: false).status.full, IslandStatus.captureStopped.full)
        XCTAssertEqual(Recovery.Stage(part: .screen, ask: true).status.full, IslandStatus.captureStopped.full)
        for part in [Recovery.Part.board, .mouse, .screen] {
            for ask in [false, true] {
                XCTAssertLessThanOrEqual(Recovery.Stage(part: part, ask: ask).status.short.count, IslandStatus.compactLimit)
            }
        }
    }

    func testMouseMustReconnectEvenWhileVideoAndAppBLEAreLive() {
        var r = Recovery(at: 100)
        var state = Recovery.Link(connected: true, frameAt: 101, hid: false)
        XCTAssertEqual(r.next(state, at: 101), .wait(.init(part: .mouse, ask: false)))
        XCTAssertEqual(r.next(state, at: 121), .wait(.init(part: .mouse, ask: true)))
        state.hid = true
        XCTAssertEqual(r.next(state, at: 122), .live)
    }

    func testAgentWaitsForMouseWhileScreenStaysLive() async throws {
        let screen = FakeScreen()
        screen.live = true
        let agent = MidsceneController(phone: FakeGestures(), screen: screen, trace: nil)
        var state = Recovery.Link(connected: true, frameAt: now(), hid: false)
        var stages: [Recovery.Stage?] = []
        var restored = 0
        agent.link = { state }
        agent.onRecover = { stages.append($0) }
        agent.restore = { restored += 1 }
        let reconnect = Task {
            try await Task.sleep(for: .milliseconds(100))
            state.hid = true
            state.frameAt = now()
        }
        let delay = try await agent.waitForScreen(poll: 0.02)
        try await reconnect.value
        XCTAssertNotNil(delay)
        XCTAssertEqual(stages, [.init(part: .mouse, ask: false), nil])
        XCTAssertEqual(restored, 1)
    }

    func testScreenRecoveryTimesOutWithoutActing() async {
        let screen = FakeScreen()
        screen.live = false
        let phone = FakeGestures()
        let agent = MidsceneController(phone: phone, screen: screen, trace: nil)
        agent.link = { Recovery.Link(connected: true, frameAt: 0, sharing: false) }
        agent.recoveryLimit = 0.05
        do { _ = try await agent.waitForScreen(poll: 0.01); XCTFail("Expected lost-screen error") }
        catch { XCTAssertEqual(error.localizedDescription, Recovery.reason(.screen)) }
        XCTAssertTrue(phone.calls.isEmpty)
    }

    func testRecoveryCanBeCancelled() async {
        let screen = FakeScreen()
        screen.live = false
        let agent = MidsceneController(phone: FakeGestures(), screen: screen, trace: nil)
        let job = Task { try await agent.waitForScreen(poll: 0.01) }
        job.cancel()
        do { _ = try await job.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
