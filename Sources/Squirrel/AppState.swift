import AppKit
import AVFoundation
import Combine
import Foundation
import SquirrelCore

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var recordingState: RecordingState = .idle
    @Published var recentIdeas: [Idea] = []
    @Published var lastError: String?
    @Published var hasOpenAIKey: Bool = false
    @Published var hasAnthropicKey: Bool = false
    @Published var micAuthorization: AVAuthorizationStatus = .notDetermined
    /// Count of forest entries not yet tagged to any project. Drives the menu-bar
    /// badge and the "ideas to triage" row — the ambient pull signal that replaced
    /// the per-message capture nudge.
    @Published var untaggedCount: Int = 0

    let preferences = Preferences.shared

    private let hotkeyManager = HotkeyManager()
    private let recorder = AudioRecorder()
    private var prefsCancellables = Set<AnyCancellable>()
    private var forestWatcher: ForestWatcher?

    private init() {
        refreshKeyState()
        refreshMicAuthorization()
    }

    func start() {
        hotkeyManager.onToggle = { [weak self] in self?.handleToggle() }
        hotkeyManager.onPressDown = { [weak self] in self?.handlePressDown() }
        hotkeyManager.onPressUp = { [weak self] in self?.handlePressUp() }
        hotkeyManager.onTextEntry = { TextIdeaWindowController.shared.showOrFocus() }
        hotkeyManager.onRegistrationFailure = { [weak self] message in
            self?.lastError = message
        }
        restartHotkeys()

        // `@Published` fires in willSet, so the property still holds the OLD
        // value when subscribers run. Hop through the main queue so by the time
        // `restartHotkeys()` reads `preferences.recordingMode` (and the two
        // hotkeys) the assignment has committed — otherwise picking
        // "Hold to record" installs the toggle path and vice versa.
        preferences.$recordingMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartHotkeys() }
            .store(in: &prefsCancellables)

        preferences.$voiceHotkey
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartHotkeys() }
            .store(in: &prefsCancellables)

        preferences.$textHotkey
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartHotkeys() }
            .store(in: &prefsCancellables)

        // Keep the untagged badge live: recompute now, and again whenever the
        // forest file changes on disk (our own captures, /stash, /scan-forest).
        refreshUntaggedCount()
        startForestWatcher()
    }

    private func startForestWatcher() {
        forestWatcher = ForestWatcher(path: preferences.forestPath) { [weak self] in
            Task { @MainActor in self?.refreshUntaggedCount() }
        }
    }

    /// Recompute the untagged-idea count off the main thread (forest read is file
    /// IO) and publish on main. Cheap — forest.md is small.
    func refreshUntaggedCount() {
        let path = preferences.forestPath
        Task.detached {
            let store = ForestStore(forestPath: path)
            let count = ((try? store.entries()) ?? []).filter { $0.projectSlugs.isEmpty }.count
            await MainActor.run { AppState.shared.untaggedCount = count }
        }
    }

    private func restartHotkeys() {
        hotkeyManager.start(
            mode: preferences.recordingMode,
            voiceHotkey: preferences.voiceHotkey,
            textHotkey: preferences.textHotkey
        )
    }

    func stop() {
        hotkeyManager.stop()
        forestWatcher?.stop()
        forestWatcher = nil
        if recorder.isRecording {
            _ = try? recorder.stop()
        }
    }

    func refreshKeyState() {
        hasOpenAIKey = !(KeychainStore.get(SecretKey.openAI) ?? "").isEmpty
        hasAnthropicKey = !(KeychainStore.get(SecretKey.anthropic) ?? "").isEmpty
    }

    func refreshMicAuthorization() {
        micAuthorization = recorder.currentAuthorization()
    }

    /// Trigger the macOS microphone prompt. If the user has already denied it, opens System Settings.
    func requestMicrophoneAccess() {
        switch recorder.currentAuthorization() {
        case .notDetermined:
            Task {
                _ = await recorder.requestPermission()
                refreshMicAuthorization()
            }
        case .denied, .restricted:
            openMicrophoneSettings()
        case .authorized:
            refreshMicAuthorization()
        @unknown default:
            openMicrophoneSettings()
        }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Hotkey handlers

    func handleToggle() {
        if recordingState == .recording {
            finishRecordingAndProcess()
        } else if !recordingState.isBusy {
            beginRecording()
        }
    }

    private func handlePressDown() {
        guard !recordingState.isBusy else { return }
        beginRecording()
    }

    private func handlePressUp() {
        guard recordingState == .recording else { return }
        finishRecordingAndProcess()
    }

    // MARK: - Recording lifecycle

    private func beginRecording() {
        guard hasOpenAIKey else {
            recordingState = .error("Set your OpenAI API key in Settings.")
            return
        }
        Task { @MainActor in
            do {
                _ = try await recorder.start()
                recordingState = .recording
                playStartSound()
            } catch {
                recordingState = .error(describe(error))
            }
            refreshMicAuthorization()
        }
    }

    private func finishRecordingAndProcess() {
        do {
            let (url, duration, peakPower) = try recorder.stop()
            playStopSound()
            recordingState = .transcribing
            Task { await processRecording(url: url, duration: duration, peakPower: peakPower) }
        } catch {
            recordingState = .error(describe(error))
        }
    }

    private func processRecording(url: URL, duration: Double, peakPower: Float) async {
        defer { try? FileManager.default.removeItem(at: url) }

        guard duration >= 0.4 else {
            recordingState = .idle
            return
        }

        // Whisper hallucinates news-anchor sign-offs and YouTube outros from
        // silent audio. Skip the round-trip entirely if the loudest sample
        // was below the silence floor.
        if peakPower < AudioRecorder.silenceThresholdDBFS {
            recordingState = .idle
            return
        }

        let openAIKey = KeychainStore.get(SecretKey.openAI)
        let whisper = WhisperService(apiKey: openAIKey, model: preferences.whisperModel)

        let transcript: String
        do {
            transcript = try await whisper.transcribe(fileURL: url)
        } catch {
            recordingState = .error(describe(error))
            return
        }

        recordingState = .summarizing
        await processIdea(text: transcript, durationSeconds: duration)
    }

    // MARK: - Typed entry path

    func submitTypedIdea(text: String) async {
        recordingState = .summarizing
        await processIdea(text: text, durationSeconds: 0)
    }

    private func processIdea(text: String, durationSeconds: Double) async {
        let service = CaptureService(
            forestPath: preferences.forestPath,
            summarizeWithClaude: preferences.summarizeWithClaude,
            anthropicKey: KeychainStore.get(SecretKey.anthropic),
            claudeModel: preferences.claudeModel
        )

        do {
            let outcome = try await service.capture(transcript: text, durationSeconds: durationSeconds)
            switch outcome {
            case .empty:
                // Silent/hallucinated audio is the common case for accidental hotkey
                // presses — drop back to idle without flagging as an error.
                recordingState = .idle
            case .captured(let idea, _):
                recentIdeas.insert(idea, at: 0)
                if recentIdeas.count > 10 { recentIdeas.removeLast(recentIdeas.count - 10) }
                recordingState = .idle
                // Deterministic, app-owned confirmation that the capture landed —
                // this replaces the old model-rendered acknowledgment block.
                CaptureToastController.shared.show(title: idea.title)
                refreshUntaggedCount()
            }
        } catch {
            recordingState = .error(describe(error))
        }
    }

    func openTextEntryWindow() {
        TextIdeaWindowController.shared.showOrFocus()
    }

    func openParkingLot() {
        ParkingLotWindowController.shared.showOrFocus()
    }

    func openForestInFinder() {
        let url = URL(fileURLWithPath: preferences.forestPath)
        NSWorkspace.shared.open(url)
    }

    // MARK: - Feedback

    private func playStartSound() {
        NSSound(named: NSSound.Name("Tink"))?.play()
    }

    private func playStopSound() {
        NSSound(named: NSSound.Name("Pop"))?.play()
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return String(describing: error)
    }
}
