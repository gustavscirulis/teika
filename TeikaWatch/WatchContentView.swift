import SwiftUI

struct WatchContentView: View {
    @Bindable var link: WatchLink
    /// `onAppear` does not fire again when the app returns from the background — the view
    /// never disappeared — so this is what tells the link it is being looked at again.
    @Environment(\.scenePhase) private var scenePhase
    /// Where a Control Center tap lands. The control's `OpenIntent` runs its `perform()`
    /// inside this app once the system has opened it, so the request is waiting here by
    /// the time the first frame is drawn.
    private let launcher = RecordingLauncher.shared

    var body: some View {
        ZStack {
            // The orb fills the display behind the system clock.
            OrbSpriteView(
                levelMeter: link.recorder.levelMeter,
                isActive: link.isRecording,
                presence: link.orbPresence
            )
            .ignoresSafeArea()

            GeometryReader { proxy in
                let shortestSide = min(proxy.size.width, proxy.size.height)
                let buttonDiameter = min(max(shortestSide * 0.46, 76), 84)

                // This geometry deliberately covers the full display. watchOS's safe
                // area is shorter at the top to make room for the clock, so centring in
                // safe-area coordinates makes the button look vertically offset.
                RecordButton(
                    phase: link.phase,
                    diameter: buttonDiameter,
                    action: link.toggleRecording
                )
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .ignoresSafeArea()

            // Messages still respect the rounded corners and bottom inset; only the
            // central control needs full-display coordinates.
            statusLine
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 2)
        }
        .onAppear {
            link.activate()
            // `initial: true` below covers a request that arrives later; this covers the
            // launch itself, where the intent has already run before any observation
            // could have been registered.
            drainLaunchRequest()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            link.setActive(phase == .active)
        }
        .onChange(of: launcher.pending) {
            drainLaunchRequest()
        }
    }

    private func drainLaunchRequest() {
        guard launcher.take() != nil else { return }
        link.requestRecording()
    }

    /// Fixed minimum height so the button does not shift as messages come and go.
    @ViewBuilder
    private var statusLine: some View {
        ZStack {
            switch link.phase {
            case .sent:
                toast("Sent to iPhone")
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            case .blocked(let reason):
                message(reason)
            case .notice(let text):
                message(text)
            // `.connecting` says nothing here on purpose — the ring around the button is
            // the whole message.
            case .idle, .recording, .connecting:
                Color.clear
            }
        }
        .frame(minHeight: 30)
        .padding(.horizontal, 10)
        .animation(.easeInOut(duration: 0.25), value: link.phase)
    }

    private func toast(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .minimumScaleFactor(0.85)
    }
}
