import Foundation
import UIKit

/// Working mode: Start → the character takes off → the phone goes to the Home Screen and the agent runs, with
/// the Live Activity as its UI, a lightweight step trace, "needs your help" pauses, notifications,
/// and the review editor at the end.
extension AppModel {

    var moveCount: Int { agent.steps.filter { !StepText.notMoves.contains($0["action"]?.str ?? "") }.count }
    var runID: String { traces.dir?.lastPathComponent ?? "" }

    /// Start a task (or a saved intent: its checklist goes to Midscene as hints).
    func run(_ task: String, intent: SavedTask? = nil) async {
        guard !startingAgent, !agent.running, !recorder.recording else { return }
        startingAgent = true
        defer { startingAgent = false }
        currentIntent = intent
        lastTask = task
        agent.hints = intent?.checklist ?? []
        startingJob = Task { await startAgent(task) }
        await startingJob?.value
        startingJob = nil
    }

    func startAgent(_ task: String) async {
        if MockMode.on { return mockRun(task) }
        guard settings.isConfigured else {
            say(String(localized: "Set up the model in Settings first."))
            return
        }
        guard board.connected && board.status?.inputReady == true else {
            say(String(localized: "Connect the mouse before starting."))
            return
        }
        let t0 = now()
        func mark(_ what: String) { DebugLog.write(String(format: "start: %@ (+%.0f ms)", what, (now() - t0) * 1000)) }
        traces.start(task: task)
        live.start(task: task, runID: runID)
        live.show(.authorizing)
        do {
            // Each task owns a new consented capture session. Do not keep a diagnostic
            // sharing session alive. Screen capture owns the background session.
            await feed.stop()
            guard await calibrator.ensureCalibrated() else { throw DeviceError(message: String(localized: "The pointer isn't calibrated yet.")) }
            try Task.checkCancellation()
            try await agent.prepare(settings)
            try await feed.start()
            mark("screen sharing ready")
            // The system sharing panel may still cover the app after consent. Home
            // dismisses it as part of leaving; no OCR or screen-coordinate click is needed.
            if UIApplication.shared.applicationState == .active {
                departing = true
                do { try await Task.sleep(for: .milliseconds(800)) }
                catch { departing = false; throw error }
                departing = false
                mark("departure animation finished")
            }
            var away = await leaveApp()
            if !away { away = await askUserToLeave() }
            guard away else { throw DeviceError(message: String(localized: "ESP32 Agent is still on screen")) }
            let left = now()
            mark("app in background")
            live.show(.looking, mood: .thinking)
            let waiting = now()
            let snapshot = try await feed.snapshot(after: left, allowUnchanged: false)
            let freshMs = (now() - waiting) * 1000
            mark("fresh frame after departure")
            DebugLog.write(String(format: "start: fresh frame wait %.0f ms, processing %.0f ms, frame age %.0f ms, JPEG %d bytes",
                                  freshMs, snapshot.processingMs,
                                  (snapshot.receivedAt - snapshot.capturedAt) * 1000, snapshot.jpeg.count))
            let settling = await feed.settled()
            mark("screen stability check finished")
            traces.write(kind: "startup-timing", snapshot.metadata.merging(settling.metadata)
                .merging(["freshFrameWaitMs": .num(freshMs)]))
            try Task.checkCancellation()
            try agent.start(task, traceStarted: true)
            mark("agent started")
            say("started: \(task)")
            began(task, early: true)
        } catch {
            departing = false
            let cancelled = error is CancellationError || Task.isCancelled
            say("cannot start: \(error.localizedDescription)")
            traces.write(feed.frame, kind: "step", ["action": .str(cancelled ? "stopped" : "error"),
                                                    "reason": .str(cancelled ? "Start cancelled" : "cannot start: \(error.localizedDescription)")])
            agent.close()
            await feed.stop()
            live.end((cancelled ? .idle : .failure, String(localized: "Could not start")))
            runs.reload()
            runMood = cancelled ? .idle : .failure
            if !cancelled {
                notifier.post(.failed, title: String(localized: "Could not start"), body: error.localizedDescription, run: runID)
                openReview(run: runID)
            }
        }
    }

    /// Emergency stop: cancel the agent and release the mouse button.
    func stopAgent() async {
        startingJob?.cancel()
        answerHelp(.stop)
        mockJob?.cancel()
        agent.stop()
        try? await Task.sleep(nanoseconds: 100_000_000)  // let a gesture in flight finish its own release
        if board.connected && !MockMode.on {
            do { try await pointer.reset() } catch { say("release failed: \(error.localizedDescription)") }
        }
        await feed.stop()
    }

    /// A run began: the character thinks, the Live Activity appears, the trace starts.
    /// early: the Live Activity and the trace were started before the agent (a real run's start sequence).
    func began(_ task: String, early: Bool = false) {
        moodReset?.cancel()
        runMood = .thinking
        runStarted = Date()
        if !early {
            live.start(task: task, runID: runID)
        }
        // RunsView reloads on appearance; finishing reloads the completed trace.
        // Avoid reading all history before the first model request can begin.
    }

    /// After each recorded step: a short "acting" hop, then back to thinking while the model looks again.
    func stepped() {
        // Agent state already supplies live progress. Disk history belongs to the
        // Runs screen, not to action callbacks on the command dispatch path.
        guard agent.running, let last = agent.steps.last, help == nil else { return }
        let moved = !StepText.notMoves.contains(last["action"]?.str ?? "")
        runMood = moved ? .acting : .thinking
        live.update(mood: runMood ?? .thinking, step: moveCount, line: StepText.line(last), phase: .running)
    }

    /// Between steps: what the character says in the Dynamic Island and where its eyes go.
    func doing(_ d: MidsceneController.Doing) {
        guard agent.running, help == nil, recovering == nil, !DeviceScreen.foreground, feed.live else { return }
        switch d {
        case .looking: live.show(.looking, mood: .thinking)
        case .waiting: live.show(.waiting, mood: .thinking)
        case .progress(let status): live.show(status)
        }
    }

    /// The run ended: outcome on the character, Live Activity and a notification; then the review opens.
    func ended() {
        help = nil
        takingOver = false
        recovering = nil
        notifier.clearHelp()
        notifier.clearLinkAsks()
        let last = agent.steps.last
        let outcome = Outcome(last: last?["action"]?.str, running: false)
        let seconds = Date().timeIntervalSince(runStarted)
        runMood = outcome.mood
        live.end((outcome.mood, last.map(StepText.line) ?? ""))
        runs.reload()
        let summary = String(localized: "\(moveCount) steps · \(seconds.durationText)")
        switch outcome {
        case .done:
            Haptics.success()
            let answer = last?["answer"]?.str ?? agent.task
            notifier.post(.done, title: String(localized: "Done: \(answer)"), body: summary, run: runID)
        case .failed:
            let why = last?["reason"]?.str ?? ""
            notifier.post(.failed, title: String(localized: "Not finished: \(why)"), body: summary, run: runID)
        default: break
        }
        if let intent = currentIntent {
            intents.record(intent.id, RunStat(run: runID, ok: outcome == .done, seconds: seconds))
        }
        if outcome != .stopped || UIApplication.shared.applicationState == .active { openReview(run: runID) }
        moodReset?.cancel()
        moodReset = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, self?.agent.running == false else { return }
            self?.runMood = nil
        }
    }

    func agentFinished() {
        ended()
        if let last = agent.steps.last { say("finished: \(last["action"]?.str ?? "") \(last["reason"]?.str ?? last["answer"]?.str ?? "")") }
    }

    // MARK: - review

    func outcome(for run: Run) -> Outcome {
        run.outcome(isActive: run.id == runID && (startingAgent || agent.running))
    }

    /// Opens the review editor for a run (with its intent, if it ran one).
    func openReview(run id: String) {
        runs.reload()
        guard let run = runs.run(id) else { return }
        let intent = intents.items.first { $0.refRun == id || $0.runs.contains { $0.run == id } }
        review = ReviewDraft(run: run, intent: intent)
    }

    /// The model rewrites the prompt and checklist from the trace and the user's corrections.
    func optimize(_ draft: ReviewDraft) async throws -> (prompt: String, hints: [String]) {
        if MockMode.on {
            try await Task.sleep(nanoseconds: 1_400_000_000)
            return (String(localized: "Open Clock › Alarms, tap +, type 0700 for the time, set Repeat to every day, then tap Save"),
                    [String(localized: "Type the time instead of scrolling the wheel"),
                     String(localized: "The + button is at the top right of Alarms"),
                     String(localized: "Check all seven days under Repeat, then tap Back")])
        }
        let reply = try await settings.client().chat(system: ReviewDraft.optimizerPrompt,
                                                              text: draft.optimizerInput(), image: nil,
                                                              maxTokens: 800, temperature: 0.2)
        guard let result = ReviewDraft.parseOptimized(reply.text) else {
            throw LLMError(message: String(localized: "The model gave no improved prompt."))
        }
        return result
    }

    // MARK: - needs your help

    /// The agent is stuck: pause, tell the user (Live Activity + notification) and wait for their choice.
    func needsHelp(_ reason: String) async -> MidsceneController.HelpChoice {
        help = reason.isEmpty ? String(localized: "I'm stuck on this step.") : reason
        runMood = .failure
        let line = String(localized: "Needs your help: \(help ?? "")")
        live.update(mood: .failure, step: moveCount, line: line, phase: .help, status: .help)
        notifier.post(.help, title: String(localized: "Needs your help"), body: help ?? "", run: runID)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { helpWait = $0 }
        } onCancel: { Task { @MainActor in self.answerHelp(.stop) } }
    }

    func answerHelp(_ choice: MidsceneController.HelpChoice) {
        guard let wait = helpWait else { return }
        resumeAsked = now()  // Continue tapped in this app: the run sends it away before looking again
        helpWait = nil
        help = nil
        takingOver = false
        notifier.clearHelp()
        runMood = choice == .stop ? .idle : .thinking
        live.update(mood: runMood ?? .thinking, step: moveCount, line: String(localized: "Going on from here…"), phase: .running,
                    status: .looking)
        wait.resume(returning: choice)
    }

    /// The user does the step by hand, then taps Continue.
    func takeOver() {
        guard help != nil else { return }
        takingOver = true
        live.update(mood: .listening, step: moveCount, line: String(localized: "Your turn. Tap Continue when you're done."),
                    phase: .help, status: .yourTurn)
        notifier.post(.takeover, title: String(localized: "Your turn"),
                      body: String(localized: "Do the step yourself, then tap Continue."), run: runID)
    }

    /// Live Activity buttons.
    func control(_ command: AgentCommand) async {
        switch command {
        case .stop: await stopAgent()
        case .resume: answerHelp(.resume)
        case .skip: answerHelp(.skip)
        case .takeOver: takeOver()
        case .stopRecording: await recorder.stop()
        }
    }

    /// Notification actions; tapping the notification itself opens the review.
    func notificationAction(_ action: Notifier.Action?, run: String) {
        switch action {
        case .stop?: Task { await stopAgent() }
        case .resume?: answerHelp(.resume)
        case .skip?: answerHelp(.skip)
        case .takeOver?: takeOver()
        case .retry?: Task { await self.run(lastTask, intent: currentIntent) }
        case .review?, nil:
            if agent.running { tab = .agent } else if !run.hasPrefix("rec-") && review == nil { openReview(run: run) }
        }
    }

}
