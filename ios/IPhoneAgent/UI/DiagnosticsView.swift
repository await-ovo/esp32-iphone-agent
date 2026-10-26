import SwiftUI

/// Live metrics and the built-in checks (screen sharing and LLM ping), plus trace export.
struct DiagnosticsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var metrics: Metrics
    @ObservedObject var board: BoardLink
    @ObservedObject var feed: ScreenCaptureFeed
    @State private var busy = false
    @State private var shareURL: URL?

    var body: some View {
        List {
            SwiftUI.Section("Tests") {
                test("Screen sharing", "camera.viewfinder") { await app.captureTest() }
                Button("Stop Screen Sharing") { Task { await feed.stop() } }
                test("LLM ping", "bolt") { await app.pingLLM() }
                Button { export() } label: { Label("Export traces", systemImage: "square.and.arrow.up") }
            }
            SwiftUI.Section("BLE") {
                row("MTU (app / board)", "\(metrics.mtu) / \(board.status?.ble?.mtu.map(String.init) ?? "–")")
                row("PHY", board.status?.ble?.phy.map { "\($0)M" } ?? "–")
                row("Status age", String(format: "%.1f s", metrics.statusAge))
            }
            SwiftUI.Section("Screen Capture") {
                row("Sharing", feed.capturing ? "On" : "Off")
                row("Resolution", "\(Int(feed.size.width)) × \(Int(feed.size.height))")
                row("Sampled fps", f(metrics.fps, "%.1f"))
                row("JPEG processing", f(metrics.captureMs, "%.1f") + " ms")
                row("Frame age", f(metrics.frameAge * 1000) + " ms")
                row("Screenshot wait", f(metrics.screenshotMs) + " ms")
                if !feed.note.isEmpty { Text(feed.note).font(.caption) }
            }
            SwiftUI.Section("Agent") {
                row("LLM first token / total", "\(f(metrics.llmFirstMs)) / \(f(metrics.llmTotalMs)) ms")
                row("LLM ping", f(metrics.llmPingMs) + " ms")
                if let s = metrics.steps.last {
                    row("Last step frame / LLM / HID", "\(f(s.frameMs)) / \(f(s.llmMs)) / \(f(s.hidMs)) ms")
                }
                ForEach(metrics.hidMs.keys.sorted(), id: \.self) { k in row("HID \(k)", f(metrics.hidMs[k]) + " ms") }
            }
            SwiftUI.Section("Background") {
                row("Alive in background", String(format: "%.0f s", metrics.backgroundAlive))
                row("Suspensions", "\(metrics.suspensions)")
            }
            SwiftUI.Section("Board") {
                row("Uptime", board.status?.up.map { "\($0 / 1000) s" } ?? "–")
                row("Reset reason", board.status?.rst ?? "–")
                row("Heap", board.status?.heap.map { "\($0 / 1024) KB" } ?? "–")
                row("Mouse", board.status?.inputState ?? "–")
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareURL) { ShareSheet(items: [$0]) }
    }

    private func test(_ title: LocalizedStringKey, _ symbol: String, _ run: @escaping () async -> Void) -> some View {
        Button {
            busy = true
            Haptics.tick()
            Task { await run(); busy = false }
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if busy { ProgressView() }
            }
        }
        .disabled(busy)
    }

    private func export() {
        do { shareURL = try TraceStore.zip(app.traces.root) } catch { app.say("export: \(error.localizedDescription)") }
    }

    private func row(_ k: LocalizedStringKey, _ v: String) -> some View { ValueRow(title: k, value: v) }

    private func f(_ v: Double?, _ format: String = "%.0f") -> String { v.map { String(format: format, $0) } ?? "–" }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
