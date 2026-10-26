import UIKit

/// Every sample uses Pointer's home → horizontal → vertical positioning. Repeated grid samples fit
/// the mapping; separate edge and weather-task targets must then pass before the mapping is saved as valid.
extension AutoCalibrator {
    enum TouchResult { case done(Double), noTaps, failed(String) }

    static let roughStops = [150, 350]
    static let targets: [(Double, Double)] = [0.12, 0.5, 0.88].flatMap { y in [0.12, 0.5, 0.88].map { x in (x, y) } }
    static let repetitions = 2
    static let verificationTargets: [(Double, Double)] = [
        (0.2, 0.2), (0.8, 0.2), (0.5, 0.62), (0.2, 0.8), (0.8, 0.8),
        (829.0 / 960, 1961.0 / 2078), (110.0 / 960, 182.0 / 2078)
    ]
    static let tapTimeout = 3.0

    func touchCalibrate(full: Bool) async throws -> TouchResult {
        let probe = app.probe, device = app.board.commands, pointer = app.pointer
        let total = (full ? Self.roughStops.count + Self.targets.count * Self.repetitions : 0) + Self.verificationTargets.count
        var clicks = 0, hits = 0
        var accepted = false
        defer { if !accepted { pointer.clearCalibration() } }
        if full { pointer.clearCalibration() }
        phase = .homing
        try await pointer.reset()

        /// The same positioning path is used for samples and real taps.
        func click(_ ux: Int, _ uy: Int) async throws -> CGPoint? {
            try await pointer.positionFromHome(ux, uy)
            let sent = now()
            try await device.send("click")
            let p = await probe.tap(since: sent, timeout: Self.tapTimeout)
            clicks += 1
            progress = Progress(done: clicks, total: total)
            if let p {
                hits += 1
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                app.say(String(format: "probe %d: move %d %d → (%.3f, %.3f) = %.0f, %.0f px", clicks, ux, uy, p.x, p.y,
                               p.x * DeviceScreen.size.width * DeviceScreen.scale,
                               p.y * DeviceScreen.size.height * DeviceScreen.scale))
            } else {
                app.say("probe \(clicks): move \(ux) \(uy) → no tap within \(Int(Self.tapTimeout)) s")
            }
            return p
        }

        /// A click that never reached the app probably hit the AssistiveTouch button and opened its menu:
        /// close the menu (esc, then a click on an empty area, which the probe swallows).
        func missed(empty: (Int, Int)?) async {
            _ = try? await device.send("key esc")
            if let (ex, ey) = empty {
                try? await pointer.positionFromHome(ex, ey)
                _ = try? await device.send("click")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        func verify() async throws -> TouchResult {
            phase = .verifying
            guard pointer.calibrated else { return .failed("not calibrated") }
            var worst = 0.0
            for (fx, fy) in Self.verificationTargets {
                try await pointer.point(fx, fy)
                let sent = now()
                try await device.send("click")
                guard let p = await probe.tap(since: sent, timeout: Self.tapTimeout) else {
                    return .failed(String(localized: "A verification tap was not received. Move the AssistiveTouch button away and try again."))
                }
                try Task.checkCancellation()
                clicks += 1
                progress = Progress(done: clicks, total: total)
                let error = max(abs(p.x - fx), abs(p.y - fy))
                app.say(String(format: "probe verify (%.3f, %.3f): landed (%.3f, %.3f), error %.2f%%", fx, fy, p.x, p.y, error * 100))
                worst = max(worst, error)
            }
            guard worst.isFinite, worst <= Self.tolerance else {
                return .failed(String(localized: "Pointer verification failed: worst error \(String(format: "%.1f", worst * 100))%. Calibrate again."))
            }
            pointer.setQuality(worst)
            accepted = true
            app.say(String(format: "probe verified: %d independent points, worst %.2f%%", Self.verificationTargets.count, worst * 100))
            return .done(worst)
        }

        if !full { return try await verify() }

        var samples: [(ux: Double, uy: Double, fx: Double, fy: Double)] = []
        func record(_ ux: Int, _ uy: Int, _ p: CGPoint?) {
            if let p { samples.append((Double(ux), Double(uy), p.x, p.y)) }
        }
        func lines() -> (ProbeFit.Line, ProbeFit.Line)? {
            let xs = samples.filter { ProbeFit.usable($0.fx) }.map { ($0.ux, $0.fx) }
            let ys = samples.filter { ProbeFit.usable($0.fy) }.map { ($0.uy, $0.fy) }
            guard let x = ProbeFit.line(xs) ?? xs.first.flatMap(ProbeFit.throughHome),
                  let y = ProbeFit.line(ys) ?? ys.first.flatMap(ProbeFit.throughHome) else { return nil }
            return (x, y)
        }

        // Stage 1: coarse distances, with the same separated axes as production positioning.
        phase = .probeA
        for u in Self.roughStops {
            let p = try await click(u, u)
            if p == nil && hits == 0 { return .noTaps }
            if p == nil { _ = try? await device.send("key esc") }  // no fit yet to place the spot or an empty click
            record(u, u, p)
        }
        guard let rough = lines() else { return .failed("probe taps stuck at the screen edge") }

        // Stage 2: repeated grid samples; reject unstable movement rather than fitting its average.
        phase = .probeB
        let empty = (rough.0.units(for: 0.5), rough.1.units(for: 0.12))
        for (fx, fy) in Self.targets {
            let ux = rough.0.units(for: fx), uy = rough.1.units(for: fy)
            guard ux > 0, uy > 0 else { return .failed("Calibration fit cannot reach the grid") }
            var previous: CGPoint?
            for _ in 0..<Self.repetitions {
                guard let p = try await click(ux, uy) else {
                    await missed(empty: empty)
                    return .failed(String(localized: "A calibration tap was not received. Move the AssistiveTouch button away and try again."))
                }
                try Task.checkCancellation()
                guard ProbeFit.usable(p.x), ProbeFit.usable(p.y) else { return .failed("Calibration tap reached the screen edge") }
                if let previous {
                    let spread = max(abs(p.x - previous.x), abs(p.y - previous.y))
                    app.say(String(format: "probe repeat (%.2f, %.2f): spread %.2f%%", fx, fy, spread * 100))
                    guard spread <= Self.tolerance else {
                        return .failed(String(localized: "Repeated pointer positions are unstable. Calibrate again."))
                    }
                }
                previous = p
                record(ux, uy, p)
            }
        }
        guard samples.count >= 4, let (lx, ly) = lines() else {
            return .failed("only \(samples.count) of \(clicks) probe clicks arrived")
        }
        app.say(String(format: "probe fit: x = %.5f·u %+.3f, y = %.5f·u %+.3f, residual %.2f%% / %.2f%% (%@)",
                       lx.a, lx.b, ly.a, ly.b, lx.rms * 100, ly.rms * 100,
                       "\(Int(DeviceScreen.size.width))×\(Int(DeviceScreen.size.height)) pt @\(Int(DeviceScreen.scale))x"))
        pointer.applyProbe(x: lx, y: ly, samples: samples)
        return try await verify()
    }
}

extension AppModel {
    /// Ask the vision model where the pointer is on a captured frame (fallback for calibration).
    func locatePointer(_ jpeg: Data) async -> CGPoint? {
        guard !MockMode.on, settings.isConfigured, let client = try? await settings.client() else { return nil }
        let system = "You find the mouse pointer on iPhone/iPad screenshots. The AssistiveTouch pointer is a small "
            + "round dark grey translucent dot. During calibration the screen is white with a grid: thin lines every "
            + "10% labelled 100-900 along the top and left edges, and coloured squares in the corners. Reply with JSON only: {\"x\": <0-1000>, \"y\": <0-1000>} for its centre, "
            + "relative to the screenshot (x left->right, y top->bottom), or {\"x\": null, \"y\": null} if there is none."
        guard let r = try? await client.chat(system: system, text: "Where is the pointer?", image: jpeg, maxTokens: 200,
                                             temperature: 0),
              let start = r.text.firstIndex(of: "{"), let end = r.text.lastIndex(of: "}"),
              let json = try? JSONSerialization.jsonObject(with: Data(r.text[start...end].utf8)) as? [String: Any],
              let x = (json["x"] as? NSNumber)?.doubleValue, let y = (json["y"] as? NSNumber)?.doubleValue,
              (0...1000).contains(x), (0...1000).contains(y) else {
            say("calibration: vision model did not find the pointer")
            return nil
        }
        return CGPoint(x: x / 1000, y: y / 1000)
    }
}
