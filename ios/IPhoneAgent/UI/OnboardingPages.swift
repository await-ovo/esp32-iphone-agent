import SwiftUI
import UIKit

/// 0 · Welcome: the character wakes up and says hello; the disclaimer must be accepted to go on.
struct WelcomePage: View {
    @Binding var accepted: Bool
    @State private var awake = false

    var body: some View {
        VStack(spacing: Space.xl) {
            PageHeader(mood: awake ? .idle : .sleeping, title: "Hi, I'm ESP32 Agent",
                       message: "Tell me a task and I'll do it on this iPhone: I see the screen with your permission and tap with a Bluetooth mouse.")
            Panel {
                DisclosureGroup {
                    Text(Disclaimer.text).font(.footnote).foregroundStyle(.secondary).padding(.top, Space.s)
                } label: {
                    Label("Understand the risks", systemImage: "exclamationmark.shield").font(.body.weight(.semibold))
                }
                Divider().padding(.vertical, Space.m)
                Toggle("I understand and accept", isOn: $accepted)
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            awake = true
        }
    }
}

enum Disclaimer {
    static var text: LocalizedStringKey {
        "ESP32 Agent is experimental software that controls this iPhone on its own. It can tap the wrong thing, send messages, change settings, buy things or delete data. Watch it while it runs and stop it if anything looks wrong. Screenshots of your screen are sent to the model endpoint you choose. You use it at your own risk; the authors accept no liability for any loss or damage."
    }
}

/// 1 · Connect the board: Bluetooth permission, scan, pair (automatically when only one board is found).
struct ConnectPage: View {
    @ObservedObject var board: BoardLink

    var body: some View {
        VStack(spacing: Space.xl) {
            PageHeader(mood: board.connected ? .success : board.scanning ? .listening : .sleeping,
                       title: "Connect My Board",
                       message: "Power the board from a USB charger or power bank. I'll find it over Bluetooth; tap Pair when iOS asks.")
            Panel {
                switch board.state {
                case .unauthorized:
                    Label("Bluetooth is not allowed for ESP32 Agent.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warning)
                    Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                        .padding(.top, Space.s)
                case .poweredOff:
                    Label("Turn on Bluetooth in Control Center.", systemImage: "antenna.radiowaves.left.and.right.slash")
                default:
                    boards
                }
            }
        }
        .onAppear { board.scan(); autoPair() }
        .onChange(of: board.state) { _, s in if s == .poweredOn { board.scan() } }
        .onChange(of: board.found) { autoPair() }
    }

    /// Only one board nearby: pair it without asking.
    private func autoPair() {
        if board.found.count == 1, board.pairedID == nil, let f = board.found.first { board.pair(f.id) }
    }

    /// Not connected → Found → Pairing → Connected. A paired board reconnects by itself when it is plugged in.
    @ViewBuilder private var boards: some View {
        if board.connected {
            CheckRow(title: "Connected to \(board.name.isEmpty ? "the board" : board.name)", done: true)
        } else if board.connecting {
            CheckRow(title: "Connecting to the board…", done: false, active: true, waiting: true)
        } else if board.linking {
            CheckRow(title: "Pairing… tap Pair when iOS asks", done: false, active: true, waiting: true)
        } else if board.pairedID == nil, board.found.count == 1, let f = board.found.first {
            CheckRow(title: "Found \(f.name)", done: false, active: true, waiting: true)
        } else if !board.found.isEmpty {
            Text("Choose your board:").font(.subheadline).foregroundStyle(.secondary)
                .padding(.bottom, Space.s)
            ForEach(board.found) { f in
                Button { board.pair(f.id) } label: {
                    HStack {
                        Text(verbatim: f.name)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, Space.s)
                }
            }
        } else {
            CheckRow(title: "Searching for the board over Bluetooth…", done: false, active: true, waiting: board.scanning)
        }
        if !board.connected || (board.signalStrength ?? 0) < -80 {
            Text((board.signalStrength ?? 0) < -80
                 ? "Weak signal? Try placing the board right against the side of your phone, or attach its antenna."
                 : "No antenna? Try placing the board right against the side of your phone.")
                .font(.footnote).foregroundStyle(.secondary).padding(.top, Space.s)
        }
        if !board.connected {
            if !board.lastError.isEmpty {
                Text(verbatim: board.lastError).font(.footnote).foregroundStyle(Palette.warning)
            }
        }
    }
}

/// Screen sharing is authorized on this iPhone, independently of the Bluetooth board.
struct SeePage: View {
    @ObservedObject var app: AppModel
    @ObservedObject var board: BoardLink
    var body: some View {
        VStack(spacing: Space.xl) {
            PageHeader(mood: app.feed.capturing ? .success : .idle, title: "Let Me See the Screen",
                       message: "Start a task to allow screen sharing. Your screen stays on this iPhone until a task sends a screenshot to your chosen model.")
            Panel {
                Label("Permission is requested when you start a task.", systemImage: "hand.raised")
                    .font(.subheadline)
                Text("Each task asks to share your screen. Sharing stops when the task ends; a full video is never saved.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.top, Space.s)
                if !app.feed.note.isEmpty { Text(verbatim: app.feed.note).foregroundStyle(Palette.warning).font(.footnote) }
            }
        }
    }
}

/// 3 · Let it act: AssistiveTouch (shown as a demo), then calibration on the grid board (bottom button).
struct ActPage: View {
    @ObservedObject var app: AppModel
    @ObservedObject var board: BoardLink
    @ObservedObject var calibrator: AutoCalibrator
    @ObservedObject var pointer: Pointer

    private var mouse: Bool { MockMode.on || board.status?.inputReady == true }
    private var sharing: Bool { MockMode.on || app.feed.capturing }

    var body: some View {
        VStack(spacing: Space.xl) {
            PageHeader(mood: pointer.calibrated ? .success : calibrator.busy ? .acting : .idle,
                       title: "Let Me Use the Pointer",
                       message: "Turn on AssistiveTouch, then open Devices › Bluetooth Devices and connect ESP32 Agent. I'll calibrate the Bluetooth mouse on a grid.")
            if !pointer.calibrated { MiniPhoneDemo(kind: .assistiveTouch) }
            Panel {
                CheckRow(title: "Mouse connected", done: mouse, active: !mouse, waiting: board.connected && !mouse)
                Divider().padding(.vertical, Space.s)
                CheckRow(title: "Screen sharing", done: sharing, active: mouse && !sharing)
                Divider().padding(.vertical, Space.s)
                CheckRow(title: "Pointer calibrated", done: pointer.calibrated, active: mouse && !pointer.calibrated,
                         waiting: calibrator.busy,
                         detail: pointer.quality.map { "Accuracy \(CalibrationText.percent($0))" })
            }
            if !pointer.calibrated {
                Label("Recommended: calibrate before first use.", systemImage: "scope")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Color.accentColor)
                Text("Tip: in AssistiveTouch › Pointer Devices, set Tracking Speed to the middle and turn Pointer Animations off.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }
}

/// 4 · Give it a brain: an OpenAI-compatible vision model; Test Connection; a first task to try.
struct BrainPage: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(spacing: Space.xl) {
            PageHeader(mood: app.modelOK == true ? .success : app.modelOK == false ? .failure : .thinking,
                       title: "Give Me a Brain",
                       message: "Choose a Midscene-supported vision model and set its model family. The key stays in this iPhone's Keychain.")
            if MockMode.on {
                Panel { Label("Demo data simulates the model.", systemImage: "theatermasks") }
            } else {
                ModelFieldsPanel(settings: settings)
            }
            ModelTestTimingView(app: app)
            switch app.modelOK {
            case true?:
                Panel {
                    if app.modelReady {
                        Label("Connected. Try this first:", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                        Text(verbatim: IntentStore.examples[0].prompt).font(.subheadline).foregroundStyle(.secondary)
                            .padding(.top, Space.s)
                    } else {
                        Text("Choose the Midscene model family in Settings.")
                    }
                }
            case false?:
                Label(app.modelError ?? String(localized: "Could not reach the model. Check the URL and key."), systemImage: "xmark.octagon.fill")
                    .foregroundStyle(Palette.stop).font(.subheadline)
            case nil:
                EmptyView()
            }
        }
    }
}

/// Endpoint and key with placeholders only; the model is picked from the endpoint (nothing personal is built in), as a grouped box.
struct ModelFieldsPanel: View {
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(spacing: Space.xs) {
            Panel { ProviderFields(settings: settings) }
            if let url = settings.provider.keyURL {
                Link("Get an API key", destination: url)
                    .font(.footnote).tint(.secondary).underline()
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }
}
