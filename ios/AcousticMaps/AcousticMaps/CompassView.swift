import SwiftUI

/// The compass mascot built from its layers (lid, base, needle, cover), so the lid can
/// flip open, the needle can spin while thinking, and the blob can pop out.
/// Layer art is 720 x 765; positions below are in that space.
struct CompassView: View {
    var open: Bool
    var blob: String?
    var blobPopped = false
    var spinning = false
    var namespace: Namespace.ID?

    private let canvas = CGSize(width: 720, height: 765)
    private let glassCenter = CGPoint(x: 303, y: 560)
    private let blobCenter = CGPoint(x: 313, y: 446)
    private let blobSize = CGSize(width: 314, height: 232)

    var body: some View {
        GeometryReader { geometry in
            let s = min(geometry.size.width / canvas.width, geometry.size.height / canvas.height)
            ZStack(alignment: .topLeading) {
                layer("CompassLid", s)
                    .rotation3DEffect(.degrees(open ? 0 : 80), axis: (x: 1, y: 0, z: 0),
                                      anchor: UnitPoint(x: 0.45, y: 0.56), perspective: 0.6)
                    .opacity(open ? 1 : 0)
                layer("CompassBase", s)
                needle(s)
                if let blob {
                    blobImage(blob, s)
                }
                layer("CompassCover", s)
                    .opacity(open ? 0 : 1)
                    .scaleEffect(open ? 1.04 : 1, anchor: .bottom)
            }
            .frame(width: canvas.width * s, height: canvas.height * s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(canvas.width / canvas.height, contentMode: .fit)
        .animation(.spring(response: 0.55, dampingFraction: 0.62), value: open)
        .animation(.spring(response: 0.42, dampingFraction: 0.55), value: blobPopped)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: blob)
        .accessibilityHidden(true)
    }

    private func layer(_ name: String, _ s: CGFloat) -> some View {
        Image(name).resizable().frame(width: canvas.width * s, height: canvas.height * s)
    }

    private func needle(_ s: CGFloat) -> some View {
        TimelineView(.animation(paused: !spinning)) { timeline in
            let turn = spinning ? timeline.date.timeIntervalSinceReferenceDate * 240 : 0
            Image("CompassNeedle").resizable()
                .frame(width: 330 * s, height: 330 * s)
                .rotationEffect(.degrees(90 + turn))
                .scaleEffect(x: 1, y: 0.5)   // lie flat on the tilted glass
                .position(x: glassCenter.x * s, y: glassCenter.y * s)
        }
        .frame(width: canvas.width * s, height: canvas.height * s)
    }

    @ViewBuilder
    private func blobImage(_ name: String, _ s: CGFloat) -> some View {
        let image = Image(name).resizable()
            .frame(width: blobSize.width * s, height: blobSize.height * s)
            .id(name)
            .transition(.scale(scale: 0.5, anchor: .bottom).combined(with: .opacity))
        let placed = Group {
            if let namespace {
                image.matchedGeometryEffect(id: "blob", in: namespace)
            } else {
                image
            }
        }
        placed.position(x: blobCenter.x * s, y: (blobCenter.y - (blobPopped ? 150 : 0)) * s)
    }
}
