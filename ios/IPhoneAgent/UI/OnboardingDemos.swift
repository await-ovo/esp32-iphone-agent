import SwiftUI

/// A looping mini-iPhone that shows where to tap for a system setting, with a finger and a caption.
/// Under Reduce Motion the frames cross-fade instead of moving.
struct MiniPhoneDemo: View {
    enum Kind { case plugIn, assistiveTouch }

    let kind: Kind
    @State private var frame = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var frames: [(caption: LocalizedStringKey, finger: CGPoint?)] {
        switch kind {
        case .plugIn:
            return [("Plug the board into the USB-C port", nil), ("Plug the board into the USB-C port", nil),
                    ("Tap Pair when iOS asks", CGPoint(x: 0.68, y: 0.56)),
                    ("No antenna? Keep it right beside your phone", nil)]
        case .assistiveTouch:
            return [("Settings › Accessibility", CGPoint(x: 0.5, y: 0.42)), ("Touch", CGPoint(x: 0.5, y: 0.22)),
                    ("AssistiveTouch", CGPoint(x: 0.5, y: 0.22)), ("Turn AssistiveTouch on", CGPoint(x: 0.84, y: 0.22))]
        }
    }

    var body: some View {
        VStack(spacing: Space.m) {
            MiniPhone { screen }
                .overlay { GeometryReader { g in finger(in: g.size) } }
                .frame(width: 132, height: 270)
                .scaleEffect(kind == .plugIn ? 5.0 / 6.0 : 1)
                .frame(width: kind == .plugIn ? 110 : 132, height: kind == .plugIn ? 225 : 270)
                .overlay(alignment: .bottomTrailing) {
                    if kind == .plugIn, frame == 3 {
                        BoardProximityIllustration()
                            .offset(x: 48, y: -Space.l)
                            .transition(.opacity)
                    }
                }
            Text(frames[frame].caption)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .id(frame)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(frames.map(\.caption).last ?? ""))
        .task(id: kind) {
            frame = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: frame == frames.count - 1 ? 2_000_000_000 : 1_300_000_000)
                withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.5, dampingFraction: 0.85)) {
                    frame = (frame + 1) % frames.count
                }
            }
        }
    }

    @ViewBuilder private func finger(in size: CGSize) -> some View {
        if let p = frames[frame].finger {
            Circle()
                .fill(Color.white.opacity(0.85))
                .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                .frame(width: 22, height: 22)
                .position(x: p.x * size.width, y: p.y * size.height)
                .transition(.opacity)
        }
    }

    // MARK: - screens

    @ViewBuilder private var screen: some View {
        switch kind {
        case .plugIn: plugIn
        case .assistiveTouch:
            switch frame {
            case 0: MiniList(title: "Settings", rows: ["General", "Display", "Accessibility", "Privacy"], hot: 2)
            case 1: MiniList(title: "Accessibility", rows: ["Touch", "Face ID", "Voice Control"], hot: 0)
            case 2: MiniList(title: "Touch", rows: ["AssistiveTouch", "Haptic Touch", "Tap to Wake"], hot: 0)
            default: MiniList(title: "AssistiveTouch", rows: ["AssistiveTouch", "Pointer Devices"], hot: 0, toggle: true)
            }
        }
    }

    private var plugIn: some View {
        ZStack {
            HomeGrid()
            if frame == 2 {
                VStack(spacing: 6) {
                    Text("Bluetooth Pairing Request").font(.system(size: 8, weight: .semibold))
                    Text(verbatim: "“ESP32 Agent”").font(.system(size: 7))
                    HStack(spacing: 0) {
                        Text("Cancel").frame(maxWidth: .infinity)
                        Text("Pair").fontWeight(.semibold).frame(maxWidth: .infinity)
                    }
                    .font(.system(size: 8))
                    .foregroundStyle(Color.blue)
                }
                .padding(8)
                .frame(width: 100)
                .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            AgentFace(mood: frame == 0 ? .sleeping : .idle, animated: false)
                .frame(width: 38, height: 42)
                .rotationEffect(.degrees(180))
                .offset(y: frame == 0 ? 70 : 38)
                .opacity(frame == 0 ? 0.6 : 1)
        }
    }


}

/// A phone outline with a Dynamic Island; the content is its screen.
struct MiniPhone<Screen: View>: View {
    @ViewBuilder let screen: Screen

    var body: some View {
        screen
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(alignment: .top) { Capsule().fill(.black).frame(width: 36, height: 10).padding(.top, 6) }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 25, style: .continuous).fill(.black))
            .overlay(RoundedRectangle(cornerRadius: 25, style: .continuous).stroke(Color(uiColor: .systemGray3), lineWidth: 1.5))
    }
}

/// A home screen of colored app icons.
private struct HomeGrid: View {
    private let colors: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .yellow, .red, .indigo, .mint, .cyan, .gray]

    var body: some View {
        LinearGradient(colors: [.indigo.opacity(0.7), .teal.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .top) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 9), count: 4), spacing: 10) {
                    ForEach(0..<12, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(colors[i]).frame(width: 20, height: 20)
                    }
                }
                .padding(.top, 34)
            }
    }
}

/// A Settings-style list with one row highlighted.
private struct MiniList: View {
    let title: LocalizedStringKey
    let rows: [LocalizedStringKey]
    let hot: Int
    var toggle = false
    var action: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11, weight: .bold)).lineLimit(1)
                Spacer()
                if let action { Text(action).font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.accentColor) }
            }
            .padding(.top, 26)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    HStack {
                        Text(row).font(.system(size: 8)).lineLimit(1)
                        Spacer()
                        if toggle && i == hot {
                            Capsule().fill(Color.green).frame(width: 18, height: 11)
                                .overlay(alignment: .trailing) { Circle().fill(.white).frame(width: 9).padding(1) }
                        } else {
                            Image(systemName: "chevron.right").font(.system(size: 6)).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(i == hot ? Color.accentColor.opacity(0.22) : Color.clear)
                    if i < rows.count - 1 { Divider().padding(.leading, 7) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            Spacer()
        }
        .padding(.horizontal, 8)
    }
}
