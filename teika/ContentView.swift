#if DEBUG
import DialKit
#endif
import SwiftData
import SwiftUI

/// Every push in the app, held in one stack path so a launch request can empty it.
/// The alternative — letting each screen own its own presentation state — leaves no
/// single place to unwind from, and a shortcut has to land on the record screen no
/// matter how deep the app was when it was last put away.
enum Route: Hashable {
    case notes
    case note(Note)
}

struct ContentView: View {
    @Bindable var transcriber: SpeechTranscriber
    @Environment(\.scenePhase) private var scenePhase
    let store: NoteStore
    let watchInbox: WatchNoteInbox
    @Query private var notes: [Note]
    @AppStorage("showsRecordingShortcutPrompt") private var showsRecordingShortcutPrompt = true
    private let launcher = RecordingLauncher.shared
    @State private var path: [Route] = []
    @State private var activeTranscript: ActiveTranscript?
    @State private var armedStart: Date?
    @State private var launchNotice: String?
    /// Set only after someone taps the disabled-looking record control while the speech
    /// model is loading. The control itself stays disabled so its glass never reacts.
    @State private var recordTapNotice: String?
    /// Identity for the transcript reveal, bumped once per transcription. Deliberately
    /// not the note's `persistentModelID`: SwiftData hands a freshly inserted model a
    /// temporary identifier and swaps it for a permanent one when the context autosaves,
    /// seconds later. Keyed on that, the reveal was rebuilt from scratch mid-life and
    /// replayed the stream-in on its own.
    @State private var revealSerial = 0
    @State private var showCopied = false
    @State private var network = NetworkMonitor()
    @State private var showsDownloadConfirmation = false
    /// Set when a transcription lands; consumed by the reveal's completion so the
    /// confirmation reads as the end of the stream-in rather than racing it.
    @State private var awaitingRevealConfirmation = false
    private let armedStartTimeout: TimeInterval = 15
    #if DEBUG
    // DialKit opens the first registered panel, so keep Debug before the more
    // specialized Orb controls.
    @StateObject private var debugDial = DialPanelState(
        name: "Debug", initial: DebugConfig(), controls: DebugConfig.dialControls,
        onAction: { path in
            guard path.hasSuffix("deleteModel") else { return }
            NotificationCenter.default.post(name: .teikaDeleteModel, object: nil)
        })
    @StateObject private var orbDial = DialPanelState(
        name: "Orb", initial: OrbConfig(), controls: OrbConfig.dialControls)
    @State private var screenshotAudioMonitor = DebugAudioLevelMonitor()
    #endif

    /// Live-tunable in debug builds; the shipped defaults everywhere else, so DialKit's
    /// panel never reaches a release build.
    private var orbConfig: OrbConfig {
        #if DEBUG
        orbDial.values
        #else
        OrbConfig()
        #endif
    }

    private var orbLevelMeter: AudioLevelMeter {
        #if DEBUG
        if showsAppStoreScreenshots { return screenshotAudioMonitor.levelMeter }
        #endif
        return transcriber.levelMeter
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                VoiceOrbView(
                    levelMeter: orbLevelMeter, isActive: isRecording,
                    config: orbConfig, presence: orbPresence
                )
                .ignoresSafeArea()
                .opacity(activeText == nil ? 1 : 0.6)
                .animation(.easeInOut(duration: 0.4), value: activeText == nil)
                VStack(spacing: 20) {
                    transcriptView
                    statusLine
                    primaryButton
                        .overlay(alignment: .top) {
                            if showsClipboardToast {
                                clipboardToast
                                    .fixedSize()
                                    .offset(y: -58)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                }
                .padding()
                // Keeps the transcript at a readable measure on iPad and in landscape
                // instead of letting it run the full width of the display.
                .frame(maxWidth: 560)
            }
            .navigationTitle("Teika")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .notes:
                    NotesListView(
                        path: $path,
                        showsRecordingShortcutPrompt: recordingShortcutPromptBinding,
                        showsEmptyState: showsEmptyNotesState,
                        showsAppStoreScreenshots: showsAppStoreScreenshots
                    )
                case .note(let note):
                    NoteDetailView(note: note)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.notes) {
                        Label("Notes", systemImage: "list.bullet")
                    }
                }
            }
            .alert("Download speech model?", isPresented: $showsDownloadConfirmation) {
                Button("Not Now", role: .cancel) {}
                Button("Download 0.5 GB") {
                    Task { await transcriber.loadModel() }
                }
            } message: {
                Text(downloadConfirmationMessage)
            }
        }
        #if DEBUG
        .overlay {
            // The drawer itself must not appear in an App Store capture. Dial values are
            // session-only, so relaunching the Debug app exits screenshot mode.
            if !showsAppStoreScreenshots {
                DialRoot(
                    position: .bottomRight, defaultOpen: false, mode: .drawer,
                    storageID: "orb")
            }
        }
        #endif
        .task {
            transcriber.onTranscription = { text in
                #if DEBUG
                // Screenshot mode is a visual fixture. Even if an already-running
                // transcription finishes after it is enabled, it must not create a note.
                guard !showsAppStoreScreenshots else { return }
                #endif
                // Only dictation started on *this* device reaches here; one from the
                // watch is saved by `PhoneWatchLink` and arrives through `watchInbox`.
                if let note = try? store.add(text: text) {
                    present(.note(note))
                } else {
                    present(.plain(text))
                }
            }
            presentWatchNote()
            drainLaunchRequest()
            await transcriber.prepareIfNeeded()
        }
        .onOpenURL { url in
            guard url.scheme == TeikaURL.scheme, url.host == TeikaURL.recordHost else { return }
            launcher.request()
        }
        .onChange(of: launcher.pending) {
            drainLaunchRequest()
        }
        .onChange(of: transcriber.state) { _, state in
            switch state {
            case .ready:
                withAnimation { recordTapNotice = nil }
                fireArmedStart()
            case .failed:
                withAnimation { recordTapNotice = nil }
                armedStart = nil
            case .needsDownload, .recording, .transcribing:
                withAnimation { recordTapNotice = nil }
            case .preparing, .loadingModel:
                break
            }
        }
        #if DEBUG
        .onChange(of: showsScreenshotRecording) { _, isActive in
            if isActive {
                Task {
                    let didStart = await screenshotAudioMonitor.start()
                    guard !didStart, showsScreenshotRecording else { return }
                    debugDial.values.showRecordingState = false
                }
            } else {
                screenshotAudioMonitor.stop()
            }
        }
        #endif
        // A clip that lands while the app is already open. Anything transcribed with the
        // app in the background is left in the inbox for the scene phase change below,
        // so the reveal plays for someone who is actually there to watch it.
        .onChange(of: watchInbox.pendingText) {
            presentWatchNote()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                armedStart = nil
                #if DEBUG
                screenshotAudioMonitor.stop()
                #endif
            }
            if phase == .active {
                presentWatchNote()
                #if DEBUG
                if showsScreenshotRecording {
                    Task {
                        let didStart = await screenshotAudioMonitor.start()
                        guard !didStart, showsScreenshotRecording else { return }
                        debugDial.values.showRecordingState = false
                    }
                }
                #endif
            }
        }
    }

    private var recordingShortcutPromptBinding: Binding<Bool> {
        #if DEBUG
        Binding(
            get: { debugDial.values.showRecordingShortcutPrompt },
            set: { debugDial.values.showRecordingShortcutPrompt = $0 }
        )
        #else
        $showsRecordingShortcutPrompt
        #endif
    }

    private var showsEmptyNotesState: Bool {
        #if DEBUG
        debugDial.values.showEmptyNotesState
        #else
        false
        #endif
    }

    private var showsAppStoreScreenshots: Bool {
        #if DEBUG
        debugDial.values.appStoreScreenshots
        #else
        false
        #endif
    }

    private var showsScreenshotRecording: Bool {
        #if DEBUG
        showsAppStoreScreenshots && debugDial.values.showRecordingState
        #else
        false
        #endif
    }

    private var showsClipboardToast: Bool {
        #if DEBUG
        if showsAppStoreScreenshots { return !showsScreenshotRecording }
        #endif
        return showCopied
    }

    /// What the transcript area is showing. Two cases because the sources age
    /// differently: a note dictated here is a live model that has to stop being read the
    /// moment it is deleted from the library, while a transcript handed over from the
    /// watch is a plain string left behind by a launch that has since ended.
    private enum ActiveTranscript {
        case note(Note)
        case plain(String)

        /// Nil once a note showing here has been deleted from the library — reading any
        /// property of a destroyed model object traps.
        var text: String? {
            switch self {
            case .note(let note):
                guard !note.isDeleted, note.modelContext != nil else { return nil }
                return note.text
            case .plain(let text):
                return text
            }
        }
    }

    private var activeText: String? {
        #if DEBUG
        if showsAppStoreScreenshots {
            return showsScreenshotRecording ? nil : AppStoreScreenshotContent.transcript
        }
        #endif
        return activeTranscript?.text
    }

    private func present(_ transcript: ActiveTranscript) {
        guard let text = transcript.text else { return }
        activeTranscript = transcript
        revealSerial += 1
        UIPasteboard.general.string = text
        awaitingRevealConfirmation = true
    }

    /// Shows the last thing dictated on the watch exactly as a dictation started here
    /// would be shown, transcript and clipboard both. The phone transcribes those clips
    /// whenever they arrive, which is usually a background launch nobody sees, so this is
    /// the first moment there is a screen to put the result on.
    private func presentWatchNote() {
        // `.inactive` rather than `.active` so a launch that is still settling still
        // shows it; what this is really excluding is the app being off screen, where the
        // reveal would play to nobody.
        guard scenePhase != .background else { return }
        switch transcriber.state {
        // Mid-recording it would appear for a second and then be replaced by whatever
        // the person is actually saying. It keeps until the app next comes forward.
        case .recording, .transcribing:
            return
        case .needsDownload, .preparing, .loadingModel, .ready, .failed:
            break
        }
        guard let text = watchInbox.take() else { return }
        present(.plain(text))
    }

    private var transcriptView: some View {
        ZStack(alignment: .topLeading) {
            if let text = activeText {
                ScrollView {
                    StreamingText(text: text) {
                        guard awaitingRevealConfirmation else { return }
                        awaitingRevealConfirmation = false
                        confirmCopy()
                    }
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id(revealSerial)
                    .contentShape(.rect)
                    .onTapGesture {
                        guard !showsAppStoreScreenshots else { return }
                        copyToClipboard(text)
                    }
                }
                .scrollContentBackground(.hidden)
            } else if showsAppStoreScreenshots {
                Color.clear
            } else if case .needsDownload = transcriber.state {
                // Lives here rather than in `statusLine` so it centres in the open space
                // above the button instead of stacking up against it.
                downloadIntro
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var clipboardToast: some View {
        Text("Copied to clipboard")
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
    }

    private var downloadIntro: some View {
        VStack(spacing: 12) {
            Text("Catch the thought\nbefore it’s gone.")
                .font(.title.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Text(
                "Accurate, fast, and private speech-to-text notes for iPhone "
                    + "and Apple Watch."
            )
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
        .padding(.horizontal, 28)
    }

    private func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
        confirmCopy()
    }

    private func confirmCopy() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { showCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { showCopied = false }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        // Fixed minimum height so the record button doesn't shift as the label
        // appears and disappears across load phases.
        ZStack {
            if showsAppStoreScreenshots {
                Color.clear
            } else {
                switch transcriber.state {
                case .failed(let message):
                    VStack(spacing: 8) {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                        Button("Try again") {
                            Task { await transcriber.loadModel() }
                        }
                        .font(.footnote)
                    }
                default:
                    if let recordTapNotice, isModelLoading {
                        Text(recordTapNotice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .transition(.opacity)
                    } else if armedStart != nil {
                        loadingLabel("Starting recording…", value: 1)
                    } else if let fraction = downloadProgress {
                        loadingLabel(
                            "Downloading model · \(Int(fraction * 100))%", value: fraction)
                    } else if showsPreparingLabel {
                        loadingLabel("Preparing model…", value: 1)
                    } else if let notice = transcriber.notice {
                        VStack(spacing: 8) {
                            Text(notice)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            if transcriber.noticeOffersSettings,
                                let url = URL(string: UIApplication.openSettingsURLString)
                            {
                                Link("Open Settings", destination: url).font(.footnote)
                            }
                        }
                    } else if let launchNotice {
                        Text(launchNotice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
        .frame(minHeight: 18)
    }

    private func loadingLabel(_ text: String, value: Double) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .contentTransition(.numericText(value: value))
    }

    /// The consent gate replaces the record button outright on first launch: there is
    /// nothing to record with until the model is on disk, so offering both would just be
    /// a dead control next to a live one.
    @ViewBuilder
    private var primaryButton: some View {
        #if DEBUG
        if showsAppStoreScreenshots {
            screenshotRecordButton
        } else {
            livePrimaryButton
        }
        #else
        livePrimaryButton
        #endif
    }

    @ViewBuilder
    private var livePrimaryButton: some View {
        if case .needsDownload = transcriber.state {
            downloadButton
        } else {
            recordButton
        }
    }

    #if DEBUG
    private var screenshotRecordButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                debugDial.values.showRecordingState.toggle()
            }
        } label: {
            Circle()
                .fill(isRecording ? Color.red.opacity(0.85) : Color.white.opacity(0.01))
                .frame(width: 84, height: 84)
                .glassEffect(
                    isRecording ? .regular.tint(.red).interactive() : .regular.interactive(),
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Show summary" : "Show recording")
        .accessibilityHint(
            "Uses microphone levels to animate the orb without transcribing or saving audio."
        )
    }
    #endif

    private var downloadButton: some View {
        Button {
            showsDownloadConfirmation = true
        } label: {
            Text("Set Up Transcription")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows details before downloading the on-device speech model.")
    }

    private var downloadConfirmationMessage: String {
        let disclosure =
            "Teika will download a 0.5 GB speech model once from Hugging Face. Only "
            + "standard connection information is shared; after that, transcription "
            + "happens locally on your iPhone."
        guard network.isExpensive else { return disclosure }
        return disclosure + " This will use cellular data."
    }

    private var recordButton: some View {
        ZStack {
            Button(action: handleRecordButtonTap) {
                Circle()
                    .fill(isRecording ? Color.red.opacity(0.85) : Color.white.opacity(0.01))
                    .frame(width: 84, height: 84)
                    .glassEffect(
                        isRecording ? .regular.tint(.red).interactive() : .regular.interactive(),
                        in: Circle()
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(recordButtonIsDisabled)
            .opacity(recordButtonIsDisabled ? 0.5 : 1)
            .accessibilityLabel(recordButtonAccessibilityLabel)
            .accessibilityHint(recordButtonAccessibilityHint)
            .accessibilityValue(accessibilityStatus)
            .overlay {
                if showsActivity {
                    LoadingRing(progress: downloadProgress)
                        .frame(width: 90, height: 90)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isRecording)
            .animation(.easeInOut(duration: 0.3), value: showsActivity)

            if isModelLoading {
                // This sibling catches the attempted tap without re-enabling the visual
                // button, so Liquid Glass has no pressed or morphing response.
                Circle()
                    .fill(.clear)
                    .frame(width: 84, height: 84)
                    .contentShape(Circle())
                    .onTapGesture { showRecordTapNotice() }
                    .accessibilityHidden(true)
            }
        }
    }

    private func showRecordTapNotice() {
        withAnimation { recordTapNotice = "Still loading the speech model…" }
    }

    private func handleRecordButtonTap() {
        switch transcriber.state {
        case .ready:
            beginFreshRecording()
        case .recording, .transcribing:
            // During transcription the same control is the documented escape hatch:
            // its spinner disappears immediately when cancellation succeeds.
            transcriber.toggleRecording()
        case .needsDownload, .preparing, .loadingModel, .failed:
            // `needsDownload` replaces this control with the download button, while a
            // load or failure disables it.
            break
        }
    }

    private var isModelLoading: Bool {
        #if DEBUG
        if debugDial.values.simulateLoading { return true }
        #endif
        return switch transcriber.state {
        case .preparing, .loadingModel: true
        case .needsDownload, .ready, .recording, .transcribing, .failed: false
        }
    }

    private var recordButtonIsDisabled: Bool {
        if isModelLoading { return true }
        if case .failed = transcriber.state { return true }
        return false
    }

    private var recordButtonAccessibilityLabel: String {
        switch transcriber.state {
        case .recording: "Stop recording"
        case .transcribing: "Cancel transcription"
        case .needsDownload, .preparing, .loadingModel, .ready, .failed: "Start recording"
        }
    }

    private var recordButtonAccessibilityHint: String {
        switch transcriber.state {
        case .preparing: "The speech model is still loading."
        case .loadingModel: "The speech model is still loading."
        case .transcribing: "Cancels the transcription in progress."
        case .failed: "Use Try again above to reload the speech model."
        case .needsDownload, .ready, .recording: ""
        }
    }

    // The ring is decorative, so the button itself has to carry load state.
    private var accessibilityStatus: String {
        switch transcriber.state {
        case .loadingModel(let fraction): "Downloading model, \(Int(fraction * 100)) percent"
        case .preparing: "Preparing model"
        case .transcribing: "Transcribing"
        case .failed: "Speech model unavailable"
        case .needsDownload: "Speech model not downloaded yet"
        case .ready, .recording: ""
        }
    }

    private var isRecording: Bool {
        if showsAppStoreScreenshots { return showsScreenshotRecording }
        if case .recording = transcriber.state { return true }
        return false
    }

    /// How far the orb has materialised, 0 = `OrbConfig.quiet`. `.preparing` branches on
    /// `didDownload` because it means two different things: the compile that follows a
    /// real download (which must not dip below the ramp it continues), and a cached
    /// launch (which starts from a floor so it settles rather than builds).
    private var orbPresence: Double {
        if showsAppStoreScreenshots { return 1 }
        return switch transcriber.state {
        case .needsDownload: 0
        case .loadingModel(let fraction): fraction * 0.9
        case .preparing: transcriber.didDownload ? 0.9 : 0.7
        case .ready, .recording, .transcribing: 1
        case .failed: 0
        }
    }

    /// Also covers `.transcribing`, where the button stays live as a cancel — without
    /// the ring it would look identical to idle.
    private var showsActivity: Bool {
        if showsAppStoreScreenshots { return false }
        #if DEBUG
        if debugDial.values.simulateLoading { return true }
        #endif
        return switch transcriber.state {
        case .preparing, .loadingModel, .transcribing: true
        case .needsDownload, .ready, .recording, .failed: false
        }
    }

    private var downloadProgress: Double? {
        #if DEBUG
        if debugDial.values.simulateLoading {
            return debugDial.values.simulateCompile ? nil : debugDial.values.fakeProgress
        }
        #endif
        if case .loadingModel(let fraction) = transcriber.state { return fraction }
        return nil
    }

    private var showsPreparingLabel: Bool {
        #if DEBUG
        if debugDial.values.simulateLoading { return debugDial.values.simulateCompile }
        #endif
        if case .preparing = transcriber.state { return transcriber.didDownload }
        return false
    }

    private func drainLaunchRequest() {
        guard let request = launcher.take() else { return }
        // Siri, the widget and the shortcuts all mean "record now", and the app may
        // have been left sitting on a note from the last time it was used. Unwind to
        // the orb first so the recording that follows is the thing on screen.
        path.removeAll()
        switch transcriber.state {
        case .ready:
            beginFreshRecording()
        case .preparing, .loadingModel:
            armedStart = request.madeAt
        case .needsDownload:
            launchNotice = "Download the speech model first — then Siri, the widget and Shortcuts can start a recording."
        case .recording, .transcribing, .failed:
            break
        }
    }

    private func fireArmedStart() {
        guard let madeAt = armedStart else { return }
        armedStart = nil
        guard Date().timeIntervalSince(madeAt) <= armedStartTimeout else { return }
        beginFreshRecording()
    }

    private func beginFreshRecording() {
        launchNotice = nil
        activeTranscript = nil
        transcriber.startRecordingIfIdle()
    }
}

#Preview {
    let store = try! NoteStore()
    return ContentView(transcriber: SpeechTranscriber(), store: store, watchInbox: WatchNoteInbox())
        .modelContainer(store.container)
}
