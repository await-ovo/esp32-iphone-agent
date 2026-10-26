import XCTest
@testable import IPhoneAgent

/// What the character says in the Dynamic Island, and where its eyes go.
@MainActor final class IslandTests: XCTestCase {
    func testDemoUsesMidsceneActionPayloadsAndStatusLabels() throws {
        let plan = try XCTUnwrap(IslandStatus.progress(["phase": "plan_thinking"]))
        XCTAssertEqual(plan.minimal, "Plan")
        XCTAssertTrue(plan.waits)
        for step in AppModel.mockSteps {
            guard !StepText.notMoves.contains(step["action"]?.str ?? "") else { continue }
            let action = try XCTUnwrap(MockMode.action(step))
            let status = try XCTUnwrap(IslandStatus.progress(["phase": "action_running", "action": action]))
            XCTAssertEqual(status.short, action["name"] as? String)
            XCTAssertFalse(status.waits)
            if step["action"]?.str == "type" {
                XCTAssertEqual(status.minimal, "Input")
                XCTAssertEqual((action["param"] as? [String: String])?["value"], step["text"]?.str)
            }
        }
        XCTAssertNil(MockMode.action(["action": .str("done")]))
    }

    func testMidscenePlannedActionsAreNotDisplayedAsExecuting() {
        XCTAssertEqual(IslandStatus.progress(["phase": "plan_action", "action": ["name": "Tap", "target": "Settings"]])?.minimal, "Next")
        XCTAssertEqual(IslandStatus.progress(["phase": "action_running", "action": ["name": "Tap", "target": "Settings"]])?.full, "aiAct → Tap · Settings")
        XCTAssertNil(IslandStatus.progress(["phase": "complete"]))
    }

    func testMinimalNamesLeaveRoomForIconAndExpandedNamesStayVerbatim() {
        for (name, minimal) in ["Tap": "Tap", "Input": "Input", "Swipe": "Swipe", "Scroll": "Scroll", "Home": "Home", "KeyboardPress": "Key", "ClearInput": "Clear", "Sleep": "Wait", "LongPress": "Hold", "DrawPath": "Draw", "FutureAction": "Act"] {
            let state = IslandStatus.progress(["phase": "action_running", "action": ["name": name]])
            XCTAssertEqual(state?.short, name)
            XCTAssertEqual(state?.minimal, minimal)
            XCTAssertEqual(state?.full, "aiAct → " + name)
        }
        XCTAssertEqual(IslandStatus.looking.short, "Screenshot")
        XCTAssertEqual(IslandStatus.looking.minimal, "Look")
        XCTAssertEqual(IslandStatus.planning.short, "Plan")
        XCTAssertEqual(IslandStatus.progress(["phase": "action_done", "action": ["name": "Tap"]])?.full, "aiAct → Tap · finished")
        XCTAssertEqual(IslandStatus.progress(["phase": "action_failed", "action": ["name": "Tap"]])?.full, "aiAct → Tap · failed")
    }

    func testActivityIconAssetsHavePresentationSizedLogicalDimensions() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let bundle = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("AgentActivity.appex")))
        let image = try XCTUnwrap(UIImage(named: "ActivityIcon44", in: bundle, compatibleWith: nil))
        XCTAssertEqual(image.size, CGSize(width: 44, height: 44))
        XCTAssertEqual(image.scale, 3)
        XCTAssertLessThanOrEqual(try XCTUnwrap(image.cgImage).width, 132)
    }

}
