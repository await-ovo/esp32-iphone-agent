import Combine
import Foundation
import UIKit

/// Wires the board, the screen feed, the pointer, the agent and the metrics together.
@MainActor final class AppModel: ObservableObject {
    /// One per process: the UI, App Intents (also when iOS launches the app in the background) and widgets use it.
    static let shared = AppModel()

    struct LogLine: Identifiable {
        let id = UUID()
        let time = Date()
        let text: String
    }

    let settings = Settings()
    let board = BoardLink(mock: MockMode.on)
    let feed = ScreenCaptureFeed()
    let metrics = Metrics()
    let traces = MockMode.on
        ? TraceStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("demo-traces"))
        : TraceStore()
    let intents = IntentStore()
    private(set) lazy var runs = RunStore(traces: traces)
    let pointer: Pointer
    let agent: MidsceneController
    @Published private(set) var log: [LogLine] = []
    @Published var refreshingStatus = false
    @Published var statusRefreshError: String?
    private var lastStatusRefresh = 0.0
    @Published var modelError: String?
    @Published var modelTestStarted: Date?
    @Published var modelTestSeconds: Double?
    @Published var modelFirstTokenSeconds: Double?
    @Published var modelResponseSeconds: Double?
    @Published var modelOK: Bool?  // last LLM ping result
    /// The character's mood during and right after a run; nil = resting (idle or sleeping, see `mood`).
    @Published var runMood: Mood?
    @Published var tab = AppTab.agent
    /// Setup page to show (onboarding, or a Home status chip deep link); nil = hidden.
    @Published var setupPage: SetupPage?
    /// The review editor on screen (after a run, a recording, or editing an intent).
    @Published var review: ReviewDraft?
    /// Paused for the user: why (nil = not paused), and whether they are doing it by hand right now.
    @Published var help: String?
    @Published var recovering: Recovery.Stage?  // the run is paused for a lost link (board, HID or screen sharing)
    var recoverySince = Date()
    @Published var takingOver = false
    @Published var departing = false  // the character's take-off before a run
    @Published var startingAgent = false
    /// A banner on Home: the app could not leave by itself (swipe up), or the run waits while the app is in front.
    @Published var homeHint: String?
    var resumeAsked = 0.0  // when Continue was tapped in the app
    let live = LiveActivityController()
    let notifier = Notifier()
    private(set) lazy var recorder = DemoRecorder(app: self)
    var startingJob: Task<Void, Never>?
    var mockJob: Task<Void, Never>?
    var moodReset: Task<Void, Never>?
    var helpWait: CheckedContinuation<MidsceneController.HelpChoice, Never>?
    var currentIntent: SavedTask?
    var lastTask = ""
    var runStarted = Date()
    private var settingsSink: AnyCancellable?
    private(set) lazy var calibrator = AutoCalibrator(app: self)
    let probe = TouchProbe()
    private var lastStatus = ""
    private var lastTick = now()
    private var lastStreamLog = 0.0
    private var timers: [Task<Void, Never>] = []
    private var hidGeneration: UInt32?
    var lastWidgetReload = 0.0

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        pointer = Pointer(device: board.commands, calibrationFile: support.appendingPathComponent("calibration.json"),
                          screen: feed)
        agent = MidsceneController(phone: pointer, screen: feed, trace: traces)
        agent.metrics = metrics
        feed.metrics = metrics

        let say: (String) -> Void = { [weak self] in self?.say($0) }
        board.log = say
        board.commands.log = say
        pointer.log = say
        pointer.screenAspect = { DeviceScreen.aspect }
        pointer.locate = { [weak self] jpeg in await self?.locatePointer(jpeg) }
        DebugLog.relay = { [weak self] line in
            // DebugLog.write runs on any thread (MetricKit delivers crash reports on a background queue).
            let relay = { MainActor.assumeIsolated { if !MockMode.on { self?.board.commands.relayLog(line) } } }
            Thread.isMainThread ? relay() : DispatchQueue.main.async(execute: relay)
        }
        board.commands.onAppCommand = { [weak self] line in self?.handleAppCommand(line) }
        DebugLog.write("app launched \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "")"
                       + " (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? ""))")
        settingsSink = settings.$configurationRevision.dropFirst().sink { [weak self] _ in
            self?.modelOK = nil
            self?.modelError = nil
            self?.modelTestSeconds = nil
            self?.modelFirstTokenSeconds = nil
            self?.modelResponseSeconds = nil
        }
        board.onStatus = { [weak self] s in
            self?.statusRefreshError = nil
            self?.pointer.useTransport("ble")
            if let generation = s.hgen, self?.hidGeneration != generation {
                self?.pointer.invalidatePosition()
                self?.hidGeneration = generation
            }
            self?.metrics.status(s)
            self?.logStatus(s)
        }
        board.onLinkUp = { [weak self] in self?.metrics.mtu = self?.board.mtu ?? 0 }
        feed.onStopped = { [weak self] reason in
            guard let self, self.agent.running else { return }
            self.say("capture unavailable: \(reason)")
            self.live.show(.captureStopped, mood: .listening)
        }
        board.commands.onTiming = { [weak self] name, ms in self?.metrics.hidMs[name] = ms }
        agent.onCleanup = { [weak self] in await self?.feed.stop() }
        agent.onFinish = { [weak self] in self?.agentFinished() }
        agent.onStep = { [weak self] in self?.stepped() }
        agent.onDoing = { [weak self] d in self?.doing(d) }
        agent.onHelp = { [weak self] reason in await self?.needsHelp(reason) ?? .stop }
        agent.gate = { [weak self] in try await self?.holdWhileInFront() }
        AgentControl.handle = { [weak self] command in await self?.control(command) }
        AgentRequests.handle = { [weak self] request in await self?.handle(request) ?? AgentRequests.unavailable }
        notifier.onAction = { [weak self] action, run in self?.notificationAction(action, run: run) }
        wireRecovery()

        timers.append(Task { [weak self] in await self?.board.commands.keepAwake(screenLive: { self?.feed.live ?? false }) })
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.tick()
            }
        })
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.metrics.enteredBackground(); DebugLog.write("app: background") }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.metrics.enteredForeground(); DebugLog.write("app: foreground") }
        }
        if MockMode.on { startMock() }
        runs.reload()
        handleLaunchArguments()
        publishWidget()
    }

    /// Every second: metrics; a suspension note; the stream's numbers every 10 s while a run goes.
    private func tick() {
        let before = metrics.suspensions, gap = now() - lastTick
        metrics.tick()
        lastTick = now()
        publishWidget()
        if metrics.suspensions > before { DebugLog.write(String(format: "app: resumed after %.0f s suspended", gap)) }
        if agent.running || startingAgent, now() - lastStreamLog >= 10 {
            lastStreamLog = now()
            DebugLog.write(String(format: "capture: %.1f fps, JPEG %.1f ms, frame age %.3f s, sharing %@",
                                  metrics.fps, metrics.captureMs, feed.updated > 0 ? now() - feed.capturedAt : -1,
                                  String(feed.capturing)))
        }
    }

    /// The run paused for the board (line) or goes on (nil).
    /// Board status changes go to the debug log (not every identical notify).
    private func logStatus(_ s: BoardStatus) {
        let line = "board status: hid \(s.inputState) rst \(s.rst ?? "-")"
        guard line != lastStatus else { return }
        lastStatus = line
        DebugLog.write(line)
        if let up = s.up, up < 30_000 {  // a link drop that is really the board rebooting (crash, brownout, ...)
            DebugLog.write("board: booted \(up / 1000) s ago (reset: \(s.rst ?? "?"), heap \((s.heap ?? 0) / 1024) KB)")
        }
    }

    /// The character's mood right now.
    var mood: Mood { runMood ?? (board.connected ? .idle : .sleeping) }

    /// The model endpoint is filled in (demo data simulates one).
    var modelReady: Bool {
        MockMode.on || (settings.isConfigured && settings.currentModel != nil
            && !settings.modelFamily.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (settings.provider == .others || !settings.apiKey.isEmpty))
    }

    func say(_ text: String) {
        log = Array((log + [LogLine(text: text)]).suffix(200))
        DebugLog.write(text)
    }

    // MARK: - setup and diagnostics

    func captureTest() async {
        guard !startingAgent, !agent.running || recovering?.part == .screen else { return }
        do {
            if feed.capturing && !feed.live { await feed.stop() }
            try await feed.start()
            say("capture: \(Int(feed.size.width))x\(Int(feed.size.height))")
        } catch { say("capture: \(error.localizedDescription)") }
    }

    /// Shared by pull-to-refresh and character interactions; rapid pokes coalesce.
    func refreshHomeStatus() async {
        guard !refreshingStatus, now() - lastStatusRefresh > 2 else { return }
        refreshingStatus = true
        statusRefreshError = nil
        defer { refreshingStatus = false; lastStatusRefresh = now(); publishWidget() }
        do {
            try await board.refreshStatus()
            runs.reload()
            say("Home status refreshed")
        } catch is CancellationError {
            return
        } catch {
            statusRefreshError = error.localizedDescription
            say("Home status refresh: \(error.localizedDescription)")
        }
    }

    func pingLLM() async {
        guard modelTestStarted == nil else { return }
        if MockMode.on {
            try? await Task.sleep(nanoseconds: 900_000_000)
            modelOK = true
            return say("LLM ok (demo data)")
        }
        let started = now()
        let revision = settings.configurationRevision
        modelError = nil
        modelOK = nil
        modelTestSeconds = nil
        modelFirstTokenSeconds = nil
        modelResponseSeconds = nil
        modelTestStarted = Date()
        defer {
            modelTestStarted = nil
            if revision == settings.configurationRevision { modelTestSeconds = now() - started }
        }
        do {
            let client = try await settings.client()
            let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }.jpegData(compressionQuality: 0.8)
            let r = try await client.chat(system: "Name the dominant color in the image. Reply with one English word.",
                                          text: "What color is this image?", image: image, maxTokens: 600, temperature: 0)
            guard revision == settings.configurationRevision else { return }
            modelFirstTokenSeconds = r.firstToken
            modelResponseSeconds = r.responseSeconds
            try ModelConnectionCheck.validate(r)
            metrics.llmPingMs = (now() - started) * 1000
            metrics.llm(first: r.firstToken, total: r.total)
            modelOK = true
            say(String(format: "LLM ok in %.0f ms: %@", metrics.llmPingMs ?? 0, String(r.text.prefix(40))))
        } catch {
            guard revision == settings.configurationRevision else { return }
            modelOK = false
            modelError = ModelRequestFailure.message(error)
            say("LLM: \(error.localizedDescription)")
        }
    }

}
