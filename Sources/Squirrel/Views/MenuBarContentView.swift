import AVFoundation
import SwiftUI
import SquirrelCore

struct MenuBarContentView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if state.micAuthorization != .authorized {
                Divider()
                micPermissionBanner
            }
            Divider()
            recordButton
            Divider()
            targetSection
            if !state.recentIdeas.isEmpty {
                Divider()
                recentSection
            }
            if let error = state.lastError {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Divider()
            footerButtons
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { state.refreshMicAuthorization() }
    }

    @ViewBuilder
    private var micPermissionBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "mic.slash.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.micAuthorization == .notDetermined
                     ? "Squirrel needs microphone access."
                     : "Microphone access is blocked.")
                    .font(.callout.weight(.semibold))
                Text(state.micAuthorization == .notDetermined
                     ? "macOS will prompt you to allow it."
                     : "Enable Squirrel under System Settings → Privacy & Security → Microphone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(state.micAuthorization == .notDetermined ? "Grant microphone access" : "Open Microphone Settings") {
                    state.requestMicrophoneAccess()
                }
                .controlSize(.small)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: state.recordingState.symbolName)
                .imageScale(.large)
                .foregroundStyle(state.recordingState == .recording ? .red : .primary)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 1) {
                Text("Squirrel")
                    .font(.headline)
                Text(state.recordingState.statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var recordButton: some View {
        VStack(spacing: 6) {
            Button {
                state.handleToggle()
            } label: {
                HStack {
                    Image(systemName: state.recordingState == .recording ? "stop.circle.fill" : "mic.circle.fill")
                    Text(state.recordingState == .recording ? "Stop recording" : "Start recording")
                    Spacer()
                    Text(state.preferences.voiceHotkey.displayString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(state.recordingState.isBusy && state.recordingState != .recording)

            Button {
                state.openTextEntryWindow()
            } label: {
                HStack {
                    Image(systemName: "square.and.pencil")
                    Text("Type an idea")
                    Spacer()
                    Text(state.preferences.textHotkey.displayString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Saving to")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: "tree.fill")
                    .foregroundStyle(.tint)
                Text(displayForestPath)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent ideas")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(state.recentIdeas.prefix(5)) { idea in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(idea.title)
                            .font(.callout)
                            .lineLimit(1)
                        Text(idea.createdAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private var footerButtons: some View {
        HStack {
            Button("Browse forest…") {
                state.openParkingLot()
            }
            Spacer()
            // `SettingsLink` and the `showSettingsWindow:` selector are both
            // unreliable in LSUIElement (menu-bar) apps. `openSettings` from
            // the SwiftUI environment is the macOS 14+ blessed API and handles
            // activation correctly.
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    private var displayForestPath: String {
        state.preferences.forestPath
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
