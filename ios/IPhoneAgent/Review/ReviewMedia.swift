import SwiftUI

/// The timeline: a tick per step (green done, red ✗ or problems, yellow unsure, gray plans), filled up to the
/// current step. Drag or tap anywhere on it to jump; VoiceOver adjusts it step by step.
struct ReviewTimeline: View {
    let steps: [DraftStep]
    @Binding var index: Int
    @Binding var playing: Bool

    var body: some View {
        GeometryReader { g in
            let n = max(steps.count, 1)
            let w = g.size.width
            let x = { (i: Int) in n > 1 ? w * CGFloat(i) / CGFloat(n - 1) : w / 2 }
            ZStack(alignment: .leading) {
                Capsule().fill(Color(uiColor: .tertiarySystemFill)).frame(height: 4)
                Capsule().fill(Color.accentColor).frame(width: x(index), height: 4)
                ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                    Capsule().fill(tint(s, i))
                        .frame(width: s.verdict == false ? 5 : 3, height: i == index ? 18 : s.verdict == false ? 14 : 10)
                        .position(x: x(i), y: g.size.height / 2)
                }
                Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .frame(width: 18, height: 18)
                    .position(x: x(index), y: g.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                playing = false
                let i = max(0, min(n - 1, Int(((v.location.x / max(w, 1)) * CGFloat(n - 1)).rounded())))
                if i != index { index = i }
            })
        }
        .frame(height: 32)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: index)
        .accessibilityElement()
        .accessibilityLabel(Text("Timeline"))
        .accessibilityValue(Text("Step \(index + 1) of \(steps.count)"))
        .accessibilityAdjustableAction { d in
            playing = false
            index = d == .increment ? min(steps.count - 1, index + 1) : max(0, index - 1)
        }
    }

    private func tint(_ s: DraftStep, _ i: Int) -> Color {
        if s.verdict == false { return Palette.stop }
        if s.uncertain { return .yellow }
        switch s.name {
        case "done": return Palette.ok
        case "fail", "error", "hiccup", "help": return Palette.stop
        case "plan", "replan (stuck)", "stopped", "takeover", "skipped": return Color(uiColor: .systemGray2)
        default: return i <= index ? Color.accentColor : Color(uiColor: .systemGray3)
        }
    }
}
