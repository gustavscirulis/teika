import SwiftUI

/// The one control.
///
/// It expresses two things, and only because neither is worth words: recording, as red
/// glass, and waiting on the link, as a ring. Everything the app has to *say* — a clip
/// sent, a reason it cannot record, something that went wrong — goes in the status line
/// beneath, so the button never becomes a second place to read and never changes colour
/// for something the user has already moved on from.
struct RecordButton: View {
    let phase: WatchLink.Phase
    let diameter: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .glassEffect(
                    isRecording
                        ? .regular.tint(.red).interactive()
                        : .regular.interactive(),
                    in: Circle()
                )
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        // Match the phone: unavailable states are communicated by the quiet orb and
        // status copy while the glass control remains visually present.
        .opacity(isEnabled ? 1 : 0.99)
        .overlay {
            if isConnecting {
                ShimmerRing()
                    .frame(width: diameter + 6, height: diameter + 6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isRecording)
        .animation(.easeInOut(duration: 0.25), value: isConnecting)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
        .accessibilityValue(accessibilityStatus)
    }

    private var fill: Color {
        isRecording ? Color.red.opacity(0.85) : Color.white.opacity(0.01)
    }

    private var isRecording: Bool { phase == .recording }
    private var isConnecting: Bool { phase == .connecting }

    /// Only the shut gate disables the button. `.sent` in particular stays live: the
    /// confirmation is a message, not a wait, and the next note can start on top of it.
    private var isEnabled: Bool {
        switch phase {
        case .idle, .recording, .notice, .sent: true
        case .connecting, .blocked: false
        }
    }

    /// VoiceOver still gets the status the sighted user reads underneath — and, for
    /// `.connecting`, the one thing the ring says that no text does.
    private var accessibilityStatus: String {
        switch phase {
        case .connecting: "Connecting to iPhone"
        case .blocked(let reason): reason
        case .sent: "Sent to iPhone"
        case .notice(let message): message
        case .idle, .recording: ""
        }
    }
}

/// The indeterminate ring from the phone's `LoadingRing`. Stands in for the word
/// "connecting", which is only ever on screen for a second or two — long enough to be
/// noticed, too short to be read as anything but a problem.
private struct ShimmerRing: View {
    @State private var spin = false

    var body: some View {
        Circle()
            .stroke(
                AngularGradient(
                    colors: [
                        .white.opacity(0), .white.opacity(0.55), .white.opacity(0),
                    ],
                    center: .center),
                lineWidth: 0.75
            )
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    spin = true
                }
            }
    }
}
