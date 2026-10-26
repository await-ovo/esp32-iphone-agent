import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct AgentActivityBundle: WidgetBundle {
    var body: some Widget {
        AgentLiveActivity()
        AgentStatusWidget()
        RunLastIntentControl()
        StopAgentControl()
    }
}

/// The Live Activity and Dynamic Island: running (app icon, action count, SDK step, Stop), needs help
/// (Continue / Skip / Stop) and recording a demonstration (red dot, timer, Stop).
struct AgentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(AgentActivityAttributes.url(run: context.attributes.runID))
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    AgentIcon(size: 36).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Counter(state: s).font(.headline).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(verbatim: context.attributes.task).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Says(state: s, full: true).font(.subheadline.weight(.semibold))
                        if let since = s.waitingSince, !s.finished {
                            Text(since, style: .timer).monospacedDigit().font(.footnote)
                                .accessibilityLabel("Waiting time")
                        }
                        if s.line != s.labelFull && (s.phase != .running || s.finished) {
                            Text(verbatim: s.line).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if !s.finished { Buttons(state: s) }
                    }
                }
            } compactLeading: {
                if s.phase == .recording {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                } else {
                    Eyes(state: s).frame(width: 18, height: 18)
                }
            } compactTrailing: {
                if s.phase == .recording && !s.finished {
                    Counter(state: s).font(.caption).frame(maxWidth: 44)
                } else {
                    Says(state: s, full: false).font(.caption.bold()).frame(maxWidth: 92, alignment: .trailing)
                }
            } minimal: {
                if s.phase == .recording {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                } else {
                    HStack(spacing: 1) {
                        Eyes(state: s).frame(width: 18, height: 18)
                        Text(verbatim: s.minimalLabel ?? s.label)
                            .font(.system(size: 8.5, weight: .semibold)).fontWidth(.condensed)
                            .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.65)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(width: 36, height: 20)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: "ESP32 Agent · " + s.labelFull))
                }
            }
            .widgetURL(AgentActivityAttributes.url(run: context.attributes.runID))
            .keylineTint(s.phase == .help ? .orange : s.phase == .recording ? .red : .white)
        }
    }
}

/// Completed action count while running, elapsed time while recording.
private struct Counter: View {
    let state: AgentActivityAttributes.ContentState
    var body: some View {
        if state.phase == .recording && !state.finished {
            Text(timerInterval: state.since...Date.distantFuture, countsDown: false)
                .monospacedDigit().foregroundStyle(.red).multilineTextAlignment(.trailing)
        } else {
            Text("\(state.step) actions").monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

private struct Buttons: View {
    let state: AgentActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 8) {
            switch state.phase {
            case .help:
                Button(intent: ContinueAgentIntent()) { Label("Continue", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .tint(.green)
                Button(intent: SkipStepIntent()) { Label("Skip", systemImage: "forward.fill").frame(maxWidth: .infinity) }
                    .tint(.gray)
                Button(intent: StopAgentIntent()) { Image(systemName: "stop.fill") }.tint(.red)
            case .recording:
                Button(intent: StopRecordingIntent()) {
                    Label("Stop Recording", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .tint(.red)
            case .running:
                Button(intent: StopAgentIntent()) { Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                    .tint(.red)
            }
        }
        .buttonStyle(.borderedProminent)
    }
}

/// The character's face without the USB tab. Waiting updates move its eyes;
/// the view interpolates each gaze change without changing the surrounding layout.
private struct Eyes: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: AgentActivityAttributes.ContentState
    var body: some View {
        AgentFace(mood: state.mood, look: state.look, lookRange: 2.4, animated: false, showsTab: false)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.65), value: state.look)
    }
}

/// The current step or outcome, colored by how things stand.
private struct Says: View {
    let state: AgentActivityAttributes.ContentState
    let full: Bool
    var body: some View {
        let text = full ? state.labelFull : state.label
        Text(verbatim: text.isEmpty ? state.line : text)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(color)
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.25), value: text)
    }

    private var color: Color {
        if state.phase == .help { return .orange }
        if state.finished { return state.mood == .success ? .green : state.mood == .failure ? .orange : .secondary }
        return .white
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<AgentActivityAttributes>

    var body: some View {
        let s = context.state
        HStack(alignment: .top, spacing: 14) {
            if s.phase == .recording && !s.finished {
                Image(systemName: "record.circle.fill").font(.system(size: 40)).foregroundStyle(.red).frame(width: 52)
            } else {
                AgentIcon(size: 44).frame(width: 52)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let name = context.attributes.name {
                    Text(verbatim: name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                HStack {
                    Text(verbatim: context.attributes.task).font(.headline).lineLimit(1)
                    Spacer()
                    Counter(state: s).font(.subheadline)
                }
                if !s.finished && !s.labelFull.isEmpty {
                    Says(state: s, full: true).font(.subheadline.weight(.semibold))
                }
                if s.phase != .running || s.finished {
                    Text(verbatim: s.line).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                if s.finished {
                    Label(s.mood == .success ? "Done · tap to review" : "Ended · tap to review",
                          systemImage: s.mood == .success ? "checkmark.circle.fill" : "play.circle")
                        .font(.footnote.weight(.semibold))
                } else {
                    Buttons(state: s).controlSize(.small)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}


/// The same icon as the app, bundled in the extension so it works without launching the app.
private struct AgentIcon: View {
    let size: CGFloat

    var body: some View {
        Image("ActivityIcon44").renderingMode(.original).resizable().scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .accessibilityHidden(true)
    }
}
