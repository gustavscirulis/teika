import SwiftUI

/* ─────────────────────────────────────────────────────────
 * REVEAL STORYBOARD — per-word stream-in on transcription
 *
 *   a tight, even stagger reveals words left-to-right;
 *   each word:         opacity 0 → 1
 *                      blur    4 → 0
 *   no translate, no jitter — precise reads as refined
 *   whole reveal bounded by `totalCap`; long text just
 *   tightens the stagger to stay within it
 *   motion:            snappy spring, no bounce — quick
 * ───────────────────────────────────────────────────────── */

private enum Reveal {
    static let baseGap = 0.02
    static let totalCap = 0.3
    static let blur: CGFloat = 4
    static let duration = 0.18
    static let anim = Animation.snappy(duration: duration, extraBounce: 0)
}

struct StreamingText: View {
    let text: String
    /// Called once the last word has finished animating in, so callers can time
    /// follow-up feedback to the end of the reveal instead of duplicating its maths.
    var onFinished: () -> Void = {}
    @State private var revealedCount = 0
    /// The text this view has already streamed in. `.task` is bound to the view's
    /// lifetime as well as to `id:`, so navigating to the notes list and back
    /// re-runs it with `text` unchanged. Gating on content rather than on
    /// appearance keeps the reveal a one-time event per transcription.
    @State private var revealedText: String?

    private var words: [String] {
        text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    var body: some View {
        let words = words
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                let shown = index < revealedCount
                Text(word)
                    .opacity(shown ? 1 : 0)
                    .blur(radius: shown ? 0 : Reveal.blur)
            }
        }
        .task(id: text) {
            // Already revealed: land on the finished state directly, and leave
            // `onFinished` alone — the copy confirmation it drives belongs to the
            // moment the transcription arrived, not to every later re-appearance.
            guard revealedText != text else {
                revealedCount = words.count
                return
            }
            // Claimed before the reveal runs, so navigating away mid-animation and
            // back settles on the finished text instead of starting over.
            revealedText = text
            revealedCount = 0
            let step = min(Reveal.baseGap, Reveal.totalCap / Double(max(words.count - 1, 1)))
            for index in words.indices {
                withAnimation(Reveal.anim) { revealedCount = index + 1 }
                guard index + 1 < words.count else { break }
                try? await Task.sleep(for: .seconds(step))
            }
            try? await Task.sleep(for: .seconds(Reveal.duration))
            guard !Task.isCancelled else { return }
            onFinished()
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
