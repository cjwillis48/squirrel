import SwiftUI
import SquirrelCore

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            KeysTab()
                .tabItem { Label("API Keys", systemImage: "key.fill") }
            StorageTab()
                .tabItem { Label("Storage", systemImage: "folder") }
        }
        .frame(width: 520, height: 360)
        .environmentObject(state)
    }
}

private struct GeneralTab: View {
    @EnvironmentObject private var state: AppState
    // Observe Preferences directly so Picker/Toggle selections re-render the
    // view on write. Without this, bindings into Preferences write the new
    // value but the view never redraws to reflect it.
    @ObservedObject private var preferences = Preferences.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Voice idea") {
                    HotkeyRecorder(
                        hotkey: state.preferences.binding(\.voiceHotkey),
                        defaultHotkey: .defaultVoice
                    )
                }
                LabeledContent("Text idea") {
                    HotkeyRecorder(
                        hotkey: state.preferences.binding(\.textHotkey),
                        defaultHotkey: .defaultText
                    )
                }

                Picker("Voice shortcut behavior", selection: state.preferences.binding(\.recordingMode)) {
                    ForEach(RecordingMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text("Push-to-talk requires Accessibility permission so Squirrel can detect when you release the keys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Hotkeys").font(.headline)
            }

            Section {
                Toggle("Summarize ideas with Claude", isOn: state.preferences.binding(\.summarizeWithClaude))
                TextField("Claude model", text: state.preferences.binding(\.claudeModel))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!state.preferences.summarizeWithClaude)
            } header: {
                Text("Summarization").font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct KeysTab: View {
    @EnvironmentObject private var state: AppState
    @State private var openAIKey: String = ""
    @State private var anthropicKey: String = ""
    @State private var showOpenAI: Bool = false
    @State private var showAnthropic: Bool = false

    var body: some View {
        Form {
            Section {
                keyField(
                    title: "OpenAI API Key",
                    placeholder: "sk-…",
                    value: $openAIKey,
                    reveal: $showOpenAI,
                    isSet: state.hasOpenAIKey
                ) {
                    KeychainStore.set(openAIKey, for: SecretKey.openAI)
                    state.refreshKeyState()
                    openAIKey = ""
                } onClear: {
                    KeychainStore.delete(SecretKey.openAI)
                    state.refreshKeyState()
                }
                Text("Used for Whisper transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("OpenAI (Whisper)").font(.headline)
            }

            Section {
                keyField(
                    title: "Anthropic API Key",
                    placeholder: "sk-ant-…",
                    value: $anthropicKey,
                    reveal: $showAnthropic,
                    isSet: state.hasAnthropicKey
                ) {
                    KeychainStore.set(anthropicKey, for: SecretKey.anthropic)
                    state.refreshKeyState()
                    anthropicKey = ""
                } onClear: {
                    KeychainStore.delete(SecretKey.anthropic)
                    state.refreshKeyState()
                }
                Text("Used to summarize ideas into a clean parking-lot entry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Anthropic (Claude)").font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private func keyField(
        title: String,
        placeholder: String,
        value: Binding<String>,
        reveal: Binding<Bool>,
        isSet: Bool,
        onSave: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) -> some View {
        HStack {
            Group {
                if reveal.wrappedValue {
                    TextField(placeholder, text: value)
                } else {
                    SecureField(placeholder, text: value)
                }
            }
            .textFieldStyle(.roundedBorder)

            Button {
                reveal.wrappedValue.toggle()
            } label: {
                Image(systemName: reveal.wrappedValue ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)

            Button("Save") { onSave() }
                .disabled(value.wrappedValue.isEmpty)

            if isSet {
                Button("Clear") { onClear() }
            }
        }

        HStack {
            Circle()
                .fill(isSet ? .green : .gray)
                .frame(width: 8, height: 8)
            Text(isSet ? "Saved in Keychain" : "Not set")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct StorageTab: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var preferences = Preferences.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Forest path", text: state.preferences.binding(\.forestPath))
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseForestPath() }
                }
                Text("All ideas are appended to this single markdown file. Use the MCP server or CLI to filter by project at retrieval time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Forest location").font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseForestPath() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.text]
        panel.nameFieldStringValue = "forest.md"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url {
            state.preferences.forestPath = url.path
        }
    }
}

// MARK: - Preferences binding helper

extension Preferences {
    func binding<Value>(_ keyPath: ReferenceWritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { self[keyPath: keyPath] = $0 }
        )
    }
}
