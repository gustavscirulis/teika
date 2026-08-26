import SwiftUI

/* ─────────────────────────────────────────────────────────
 * LOADING STORYBOARD — first-run model load, two phases
 *
 *   download:  determinate arc grows clockwise from 12 o'clock
 *              a faint track stays behind it so the remainder
 *              reads as "how much is left", not "nothing there"
 *   compile:   no measurable progress — the arc dissolves into
 *              an indeterminate shimmer that is already spinning
 *              underneath, so the handoff never pops
 *   motion:    the arc smooths FluidAudio's byte-level callback
 *              cadence; the phase change is a plain cross-fade —
 *              no scale, no rotation, the ring never moves
 * ───────────────────────────────────────────────────────── */

private enum Loading {
    static let lineWidth: CGFloat = 0.75
    static let trackOpacity = 0.22
    static let arcOpacity = 0.9
    static let shimmerOpacity = 0.55
    static let spin = 1.1
    static let progress = Animation.smooth(duration: 0.3)
    static let crossFade = Animation.easeInOut(duration: 0.35)
}

struct LoadingRing: View {
    /// `nil` when there is no measurable progress — shows the shimmer instead.
    let progress: Double?

    var body: some View {
        ZStack {
            ShimmerRing()
                .opacity(progress == nil ? 1 : 0)
            DownloadRing(progress: progress ?? 0)
                .opacity(progress == nil ? 0 : 1)
        }
        .animation(Loading.crossFade, value: progress == nil)
    }
}

private struct DownloadRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.white.opacity(Loading.trackOpacity), lineWidth: Loading.lineWidth)
            // A trimmed Circle is no longer insettable, so match strokeBorder's
            // geometry by hand to keep both rings on the same radius.
            Circle()
                .inset(by: Loading.lineWidth / 2)
                .trim(from: 0, to: progress)
                .stroke(
                    .white.opacity(Loading.arcOpacity),
                    style: StrokeStyle(lineWidth: Loading.lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .animation(Loading.progress, value: progress)
    }
}

private struct ShimmerRing: View {
    @State private var angle = 0.0

    var body: some View {
        Circle()
            .strokeBorder(
                AngularGradient(
                    colors: [.clear, .clear, .white.opacity(Loading.shimmerOpacity), .clear],
                    center: .center),
                lineWidth: Loading.lineWidth
            )
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: Loading.spin).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

#Preview {
    @Previewable @State var progress: Double? = 0
    ZStack {
        Color(white: 0.04)
        LoadingRing(progress: progress)
            .frame(width: 90, height: 90)
    }
    .ignoresSafeArea()
    .task {
        while !Task.isCancelled {
            for step in 0...100 {
                progress = Double(step) / 100
                try? await Task.sleep(for: .milliseconds(30))
            }
            progress = nil
            try? await Task.sleep(for: .seconds(2))
            progress = 0
        }
    }
}
