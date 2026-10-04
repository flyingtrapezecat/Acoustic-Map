import SwiftUI

/// Buttons press in slightly with a spring, so taps feel physical.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Bouncing bars under "Listening", driven by the microphone level.
struct WaveformBars: View {
    let level: Double
    private let count = 9

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(Color("Action"))
                        .frame(width: 5, height: barHeight(index, t))
                }
            }
            .frame(height: 46)
        }
        .accessibilityHidden(true)
    }

    private func barHeight(_ index: Int, _ t: Double) -> CGFloat {
        let wave = (sin(t * 7 + Double(index) * 0.9) + 1) / 2
        let loud = max(level, 0.18)
        return CGFloat(8 + (10 + 28 * loud) * wave)
    }
}

/// A one-shot burst of colored bits (arrival). Fires each time `trigger` changes.
struct ConfettiBurst: View {
    let trigger: Int
    @State private var fired = false
    @State private var pieces: [Piece] = []

    struct Piece: Identifiable {
        let id = UUID()
        let dx: CGFloat, dy: CGFloat, size: CGFloat, spin: Double
        let color: Color, round: Bool
    }

    var body: some View {
        ZStack {
            ForEach(pieces) { piece in
                Group {
                    if piece.round { Circle().stroke(piece.color, lineWidth: 2) } else { Rectangle().fill(piece.color) }
                }
                .frame(width: piece.size, height: piece.size)
                .rotationEffect(.degrees(fired ? piece.spin : 0))
                .offset(x: fired ? piece.dx : 0, y: fired ? piece.dy : 0)
                .opacity(fired ? 0 : 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _, _ in burst() }
    }

    private func burst() {
        let colors = [Color("CompassGold"), Color("Action"), Color("BlobLavender"), Color.teal]
        pieces = (0..<22).map { _ in
            let angle = Double.random(in: 0..<(2 * .pi))
            let distance = CGFloat.random(in: 90...190)
            return Piece(dx: cos(angle) * distance, dy: sin(angle) * distance - 40,
                         size: .random(in: 6...12), spin: .random(in: -240...240),
                         color: colors.randomElement()!, round: Bool.random())
        }
        fired = false
        withAnimation(.easeOut(duration: 1.6)) { fired = true }
    }
}

/// Rings around the mic button that swell with the voice level while listening.
struct ListeningRings: View {
    let level: Double
    let active: Bool
    let size: CGFloat
    @State private var breathe = false

    var body: some View {
        ZStack {
            ring(0)
            ring(1)
        }
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: level)
        .animation(.easeInOut(duration: 0.3), value: active)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { breathe = true }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func ring(_ index: Int) -> some View {
        let grow: CGFloat = 1.12 + CGFloat(index) * 0.18 + CGFloat(level) * 0.35 + (breathe ? 0.04 : 0)
        let color: Color = Color("Action").opacity(index == 0 ? 0.45 : 0.25)
        return Circle()
            .stroke(color, lineWidth: 3)
            .frame(width: size, height: size)
            .scaleEffect(active ? grow : 1)
            .opacity(active ? 1 : 0)
    }
}

/// A spinning arc around a button while the server (or the agent) is thinking.
struct ThinkingRing: View {
    let active: Bool
    let size: CGFloat
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(Color("CompassGold"), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .frame(width: size + 14, height: size + 14)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .opacity(active ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: active)
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A gentle idle bob (faster while thinking). Still when Reduce Motion is on.
struct Bobbing: ViewModifier {
    let amount: CGFloat
    let fast: Bool
    @State private var up = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(y: reduceMotion ? 0 : (up ? -amount : amount))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: fast ? 0.5 : 1.4).repeatForever(autoreverses: true)) { up = true }
            }
    }
}
