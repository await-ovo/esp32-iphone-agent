import XCTest
@testable import IPhoneAgent

/// Needs-your-help pauses, intent hints, the AI optimizer's reply and demonstration drafts.
@MainActor final class ReviewTests: XCTestCase {
    func testIntentHintsAreIncludedInMidsceneTask() {
        let agent = MidsceneController(phone: nil, screen: nil, trace: nil)
        agent.showMock(task: "Set an alarm", plan: "", steps: [], running: false)
        agent.hints = ["Type the time"]
        XCTAssertEqual(agent.prompt, "Set an alarm\n\nHints for this task:\n- Type the time")
    }

    func testOptimizerReplyIsParsed() {
        let r = ReviewDraft.parseOptimized("Sure.\nPROMPT: Set a 7 AM alarm\nHINTS:\n- Type the time\n- Tap Save\n")
        XCTAssertEqual(r?.prompt, "Set a 7 AM alarm")
        XCTAssertEqual(r?.hints, ["Type the time", "Tap Save"])
        XCTAssertNil(ReviewDraft.parseOptimized("no idea"))
    }

    func testDemonstrationReplyBecomesADraftWithUnsureSteps() {
        let frames = (1...3).map { URL(fileURLWithPath: "/tmp/k00\($0).jpg") }
        let draft = DemoRecorder.draft("""
        NAME: Alarm
        PROMPT: Set an alarm
        STEP 1: tap 500 814 | sure
        STEP 3: type "0700" | unsure
        STEP 2: something odd | sure
        """, frames: frames, folder: URL(fileURLWithPath: "/tmp/none"))
        XCTAssertEqual(draft.name, "Alarm")
        XCTAssertEqual(draft.prompt, "Set an alarm")
        XCTAssertEqual(draft.steps.map(\.name), ["tap", "type", "note"])
        XCTAssertEqual(draft.steps.map(\.uncertain), [false, true, true])
        XCTAssertEqual(draft.steps[1].frame, frames[2])
    }

    func testCorrectionsReachTheOptimizerInput() {
        let draft = ReviewDraft(source: .run, folder: nil, runID: nil, outcome: .failed,
                                steps: [DraftStep(action: ["action": .str("tap"), "x": .int(1), "y": .int(2)])],
                                name: "", prompt: "Set an alarm")
        draft.setFix(draft.steps[0].id, point: CGPoint(x: 905, y: 88), note: "tap the +")
        draft.insert(after: draft.steps[0].id, text: "then tap Save")
        let text = draft.optimizerInput()
        XCTAssertTrue(text.contains("[USER: wrong]"))
        XCTAssertTrue(text.contains("the right spot is 905 88"))
        XCTAssertTrue(text.contains("[USER NOTE: tap the +]"))
        XCTAssertTrue(text.contains("[ADDED BY USER]"))
        XCTAssertEqual(draft.corrections, 2)
    }
    func testReportUsesMidsceneNamesAndStructuredParameters() {
        let input: JObject = ["action": .str("type"), "sdkAction": .str("Input"),
                              "sdkParam": .obj(["value": .str("08:00"), "mode": .str("replace")])]
        XCTAssertEqual(StepText.reportTitle(input), "aiAct → Input")
        XCTAssertEqual(StepText.reportParameters(input), "{\"value\": \"08:00\", \"mode\": \"replace\"}")
        XCTAssertEqual(StepText.reportTitle(["action": .str("tap"), "sdkAction": .str("Tap")]), "aiAct → Tap")
        XCTAssertEqual(StepText.reportTitle(["action": .str("home")]), StepText.title(["action": .str("home")]))
        XCTAssertNil(StepText.reportParameters(["sdkParam": .obj([:])]))
    }

    func testExistingTraceRestoresTargetsWithoutAddingFakeActionSteps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trace = TraceStore(root: root)
        trace.start(task: "Open Clock")
        trace.write(kind: "progress", ["phase": .str("action_running"), "name": .str("Tap"), "target": .str("Clock icon")])
        trace.write(kind: "step", ["id": .int(0), "action": .str("tap"), "sdkAction": .str("Tap"), "status": .str("running")])
        trace.write(kind: "step-update", ["id": .int(0), "status": .str("completed")])
        trace.write(kind: "step", ["id": .int(1), "action": .str("done")])
        let run = try XCTUnwrap(RunStore.load(try XCTUnwrap(trace.dir)))
        XCTAssertEqual(run.steps.count, 2)
        XCTAssertEqual(run.steps[0].action["target"]?.str, "Clock icon")
        XCTAssertEqual(run.steps[0].action["status"]?.str, "completed")
        XCTAssertNil(run.steps[1].action["target"])
    }

}
