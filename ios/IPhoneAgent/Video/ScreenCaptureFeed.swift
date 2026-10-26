import CoreImage
import CoreMedia
import ImageIO
import UIKit
import UniformTypeIdentifiers
#if canImport(ScreenCaptureKit)
@preconcurrency import ScreenCaptureKit
#endif

struct ScreenCaptureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ScreenSnapshot {
    let jpeg: Data
    let id: Int
    let size: CGSize
    let capturedAt: Double
    let receivedAt: Double
    let processingMs: Double
    var metadata: JObject {
        ["frameSource": .str("ScreenCaptureKit"), "frameID": .int(id), "frameCapturedAt": .num(capturedAt),
         "frameReceivedAt": .num(receivedAt), "frameWidth": .num(size.width), "frameHeight": .num(size.height),
         "frameProcessingMs": .num(processingMs), "frameBytes": .int(jpeg.count)]
    }
}

struct ScreenSettleResult {
    enum Reason: String { case quiet, timeout, cancelled }
    let elapsedMs: Double
    let comparisonMs: Double
    let comparisons: Int
    let reason: Reason
    var metadata: JObject {
        ["settleMs": .num(elapsedMs), "comparisonMs": .num(comparisonMs),
         "comparisons": .int(comparisons), "settleReason": .str(reason.rawValue)]
    }
}

/// The pointer and Midscene share one screen source; tests supply still frames through the same contract.
@MainActor protocol ScreenSource: AnyObject {
    var live: Bool { get }
    var frame: Data? { get }
    var updated: Double { get }
    var capturedAt: Double { get }
    var aspect: Double { get }
    func afterAction(since: Double) async
}

extension ScreenSource {
    func afterAction(since: Double) async { await settled() }

    @discardableResult
    func settled(quiet: Double = 0.25, least: Double = 0.2, most: Double = 1) async -> ScreenSettleResult {
        let started = now()
        var previous = frame, changed = started
        var checked = previous
        var comparisons = 0, comparisonMs = 0.0
        func result(_ reason: ScreenSettleResult.Reason) -> ScreenSettleResult {
            let value = ScreenSettleResult(elapsedMs: (now() - started) * 1000, comparisonMs: comparisonMs,
                                          comparisons: comparisons, reason: reason)
            DebugLog.write(String(format: "screen: settle %@, total %.0f ms, compare %.0f ms (%d comparisons)",
                                  reason.rawValue, value.elapsedMs, comparisonMs, comparisons))
            return value
        }
        try? await Task.sleep(for: .seconds(least))
        while !Task.isCancelled, now() - started < most {
            let candidate = frame
            if candidate == nil { changed = now() }
            else if candidate != checked {
                checked = candidate
                // Compare each distinct JPEG once, away from the main actor. Keep the
                // last materially different baseline so small changes can accumulate.
                if candidate != previous {
                    let baseline = previous
                    let comparison = await Task.detached(priority: .userInitiated) {
                        let began = now()
                        let changed = Vision.changed(baseline, candidate)
                        return (changed, (now() - began) * 1000)
                    }.value
                    comparisons += 1; comparisonMs += comparison.1
                    if Task.isCancelled { return result(.cancelled) }
                    if comparison.0 { previous = candidate; changed = now() }
                    // New frames can arrive while the comparison runs. Inspect them
                    // before declaring quiet, rather than accepting an older image.
                    if frame != candidate { continue }
                }
            }
            if now() - changed >= quiet { return result(.quiet) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return result(Task.isCancelled ? .cancelled : .timeout)
    }

    func fresh(since: Double, timeout: Double = 1) async -> Data? {
        let deadline = now() + timeout
        while live, !Task.isCancelled {
            if capturedAt > since, let frame { return frame }
            if now() >= deadline { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}

/// User-authorized full-display capture. Only the latest JPEG lives here; TraceStore owns step images.
@MainActor final class ScreenCaptureFeed: NSObject, ObservableObject, ScreenSource {
    @Published private(set) var frame: Data?
    @Published private(set) var size = CGSize.zero
    @Published private(set) var choosing = false
    @Published private(set) var capturing = false
    @Published private(set) var note = ""
    private(set) var updated = 0.0
    private(set) var capturedAt = 0.0
    private(set) var frameID = 0
    private var latest: ScreenSnapshot?
    var metrics: Metrics?
    var onStopped: ((String) -> Void)?
    #if canImport(ScreenCaptureKit)
    private lazy var picker = SCContentSharingPicker.shared
    private var callbacks: CaptureCallbacks!
    private var stream: SCStream?
    private var output: CaptureOutput?
    private var generation: UUID?
    private var selection: CheckedContinuation<Void, Error>?
    private var registered = false
    #endif
    private var mock = false

    override init() {
        super.init()
        #if canImport(ScreenCaptureKit)
        callbacks = CaptureCallbacks(owner: self)
        #endif
    }
    // A quiet display need not produce new pixels. Session/status callbacks, rather
    // than the age of unchanged content, determine whether its latest image is usable.
    var live: Bool { (capturing || mock) && frame != nil }
    var aspect: Double { size.height > 0 ? size.width / size.height : DeviceScreen.aspect }

    /// The picker is always presented in front; a cancelled request cannot start a late stream.
    func start() async throws {
        #if canImport(ScreenCaptureKit)
        if capturing { return }
        guard !choosing, stream == nil else { throw ScreenCaptureError(message: String(localized: "Screen sharing is already starting.")) }
        guard UIApplication.shared.applicationState == .active else {
            throw ScreenCaptureError(message: String(localized: "Open the app to allow screen sharing."))
        }
        try Task.checkCancellation()
        let id = UUID()
        generation = id; note = ""; frame = nil; updated = 0; capturedAt = 0; frameID = 0
        let began = now()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    selection = continuation
                    var config = SCContentSharingPickerConfiguration()
                    config.showsMicrophoneControl = false
                    picker.defaultConfiguration = config
                    picker.add(callbacks); registered = true
                    choosing = true; picker.isActive = true
                    DebugLog.write("capture: presenting full-display picker")
                    picker.present()
                }
            } onCancel: { Task { @MainActor [weak self] in if self?.generation == id { await self?.stop() } } }
            try Task.checkCancellation()
            _ = try await image(timeout: 5)
            choosing = false
            DebugLog.write(String(format: "capture: authorized and ready in %.3f s", now() - began))
        } catch { await stop(); throw error }
        #else
        throw ScreenCaptureError(message: String(localized: "Screen capture requires a physical iPhone."))
        #endif
    }

    #if canImport(ScreenCaptureKit)
    fileprivate func selected(_ filter: SCContentFilter) async {
        guard choosing, stream == nil, let id = generation else { return }
        let receiver = CaptureOutput(publish: { [weak self] image in
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.frame = image.jpeg; self.size = image.size
                self.updated = now(); self.capturedAt = image.capturedAt; self.frameID += 1
                self.latest = ScreenSnapshot(jpeg: image.jpeg, id: self.frameID, size: image.size,
                                             capturedAt: image.capturedAt, receivedAt: self.updated, processingMs: image.processingMs)
                self.metrics?.frameCaptured(ms: image.processingMs, age: max(0, self.updated - image.capturedAt))
            }
        }, unavailable: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.invalidateFrame()
            }
        })
        let config = SCStreamConfiguration()
        config.capturesAudio = false
        let next = SCStream(filter: filter, configuration: config, delegate: callbacks)
        output = receiver; stream = next
        do {
            try next.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
            try await next.startCapture()
            guard generation == id else { return }
            capturing = true
            let continuation = selection; selection = nil
            continuation?.resume()
            DebugLog.write("capture: stream started")
        } catch { await failed(error, stream: next) }
    }

    fileprivate func cancelledSelection() async {
        // Cancelling a picker update must not revoke a stream that was already authorized.
        guard choosing, stream == nil else { return }
        await stop()
    }

    #endif

    func stop() async {
        choosing = false; capturing = false; mock = false
        #if canImport(ScreenCaptureKit)
        generation = nil
        output?.disable(); output = nil
        let previous = stream; stream = nil
        let continuation = selection; selection = nil
        continuation?.resume(throwing: CancellationError())
        if registered { picker.isActive = false; picker.remove(callbacks); registered = false }
        #endif
        // A stopped session must never supply a cached screenshot to a later run.
        invalidateFrame()
        #if canImport(ScreenCaptureKit)
        try? await previous?.stopCapture()
        #endif
    }

    #if canImport(ScreenCaptureKit)
    fileprivate func failed(_ error: Error, stream stopped: SCStream? = nil) async {
        if let stopped, stream !== stopped { return }
        let message = error.localizedDescription
        let continuation = selection; selection = nil
        continuation?.resume(throwing: error)
        await stop()
        note = message
        DebugLog.write("capture: stopped: \(message)")
        onStopped?(message)
    }

    #endif

    func invalidateFrame() {
        frame = nil; latest = nil; updated = 0; capturedAt = 0
    }

    /// Startup/recovery barriers require pixels displayed after the transition.
    func image(after action: Double? = nil, timeout: Double = 5) async throws -> Data {
        try await snapshot(after: action, timeout: timeout, allowUnchanged: false).jpeg
    }

    /// Model observations may show that an action left the screen unchanged. Keep
    /// the original content timestamp; never manufacture a newer capture time.
    func snapshot(after action: Double? = nil, timeout: Double = 5, allowUnchanged: Bool = true) async throws -> ScreenSnapshot {
        let started = now(), deadline = started + timeout
        while true {
            try Task.checkCancellation()
            guard capturing || mock else { throw ScreenCaptureError(message: note.isEmpty ? String(localized: "Screen sharing has stopped. Open the app to share the screen again.") : note) }
            let ready = action.map { capturedAt > $0 || (allowUnchanged && now() - $0 >= 0.3) } ?? true
            if live, ready, let latest {
                metrics?.screenshotMs = (now() - started) * 1000
                return latest
            }
            guard now() < deadline else { throw ScreenCaptureError(message: String(localized: "No fresh screen image arrived. Open the app to restart screen sharing.")) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func afterAction(since: Double) async {
        _ = await fresh(since: since, timeout: 1)
        await settled()
    }

    /// Demo data and deterministic screen-source tests never present a system picker.
    func show(_ jpeg: Data, width: Int, height: Int, captured: Double? = nil) {
        mock = true; frame = jpeg; size = CGSize(width: width, height: height)
        updated = now(); capturedAt = captured ?? updated; frameID += 1
        latest = ScreenSnapshot(jpeg: jpeg, id: frameID, size: size, capturedAt: capturedAt, receivedAt: updated, processingMs: 0)
    }
}

#if canImport(ScreenCaptureKit)
private final class CaptureCallbacks: NSObject, SCContentSharingPickerObserver, SCStreamDelegate, @unchecked Sendable {
    weak var owner: ScreenCaptureFeed?
    init(owner: ScreenCaptureFeed) { self.owner = owner }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in await self?.owner?.selected(filter) }
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in await self?.owner?.cancelledSelection() }
    }
    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in await self?.owner?.failed(error) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in await self?.owner?.failed(error, stream: stream) }
    }
}

/// Serialize conversion and drop excess samples rather than building a video backlog.
private final class CaptureOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Image: Sendable { let jpeg: Data; let size: CGSize; let capturedAt: Double; let processingMs: Double }
    let queue = DispatchQueue(label: "screen.capture", qos: .userInitiated)
    private let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    private let publish: @Sendable (Image) -> Void
    private let unavailable: @Sendable () -> Void
    private var wasUnavailable = false
    private var enabled = true
    private var last = -Double.infinity
    init(publish: @escaping @Sendable (Image) -> Void, unavailable: @escaping @Sendable () -> Void) {
        self.publish = publish; self.unavailable = unavailable
    }
    func disable() { queue.sync { enabled = false } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard enabled, type == .screen, sample.isValid else { return }
        let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds, wall = now()
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let status = info[.status] as? Int else { return }
        if [SCFrameStatus.blank, .suspended, .stopped].contains(where: { $0.rawValue == status }) {
            if !wasUnavailable { unavailable() }
            wasUnavailable = true; last = -Double.infinity
            return
        }
        guard status == SCFrameStatus.complete.rawValue || status == SCFrameStatus.started.rawValue else { return }
        wasUnavailable = false
        guard host - last >= 0.25,
              let raw = info[.displayTime] as? NSNumber, let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        // SDK declares displayTime as mach absolute time. Convert using CoreMedia's host clock,
        // then map into the wall clock used by HID actions. A missing/invalid clock never looks fresh.
        let displayed = CMClockMakeHostTimeFromSystemUnits(raw.uint64Value).seconds
        guard displayed.isFinite, displayed > 0, displayed <= host + 0.05 else { return }
        last = host
        autoreleasepool {
            let input = CIImage(cvPixelBuffer: pixels)
            let scale = min(1, 960 / input.extent.width)
            let image = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = context.createCGImage(image, from: image.extent) else { return }
            let bytes = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return }
            publish(Image(jpeg: bytes as Data, size: CGSize(width: cg.width, height: cg.height),
                          capturedAt: wall + min(0, displayed - host),
                          processingMs: (CMClockGetTime(CMClockGetHostTimeClock()).seconds - host) * 1000))
        }
    }
}

#endif
