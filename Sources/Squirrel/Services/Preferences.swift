import Foundation
import Combine
import SquirrelCore

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults(suiteName: Configuration.suiteName) ?? .standard

    private enum Keys {
        static let recordingMode = "recordingMode"
        static let summarizeWithClaude = "summarizeWithClaude"
        static let claudeModel = "claudeModel"
        static let whisperModel = "whisperModel"
        static let forestPath = "forestPath"
        static let voiceHotkey = "voiceHotkey"
        static let textHotkey = "textHotkey"
    }

    @Published var recordingMode: RecordingMode {
        didSet { defaults.set(recordingMode.rawValue, forKey: Keys.recordingMode) }
    }

    @Published var summarizeWithClaude: Bool {
        didSet { defaults.set(summarizeWithClaude, forKey: Keys.summarizeWithClaude) }
    }

    @Published var claudeModel: String {
        didSet { defaults.set(claudeModel, forKey: Keys.claudeModel) }
    }

    @Published var whisperModel: String {
        didSet { defaults.set(whisperModel, forKey: Keys.whisperModel) }
    }

    @Published var forestPath: String {
        didSet { defaults.set(forestPath, forKey: Keys.forestPath) }
    }

    @Published var voiceHotkey: Hotkey {
        didSet { saveHotkey(voiceHotkey, key: Keys.voiceHotkey) }
    }

    @Published var textHotkey: Hotkey {
        didSet { saveHotkey(textHotkey, key: Keys.textHotkey) }
    }

    private init() {
        let defaultForestPath = (NSHomeDirectory() as NSString).appendingPathComponent("forest.md")

        self.recordingMode = RecordingMode(rawValue: defaults.string(forKey: Keys.recordingMode) ?? "") ?? .toggle
        self.summarizeWithClaude = defaults.object(forKey: Keys.summarizeWithClaude) as? Bool ?? true
        self.claudeModel = defaults.string(forKey: Keys.claudeModel) ?? "claude-sonnet-4-6"
        self.whisperModel = defaults.string(forKey: Keys.whisperModel) ?? "whisper-1"
        self.forestPath = defaults.string(forKey: Keys.forestPath) ?? defaultForestPath
        self.voiceHotkey = Self.loadHotkey(key: Keys.voiceHotkey, fallback: .defaultVoice, defaults: defaults)
        self.textHotkey = Self.loadHotkey(key: Keys.textHotkey, fallback: .defaultText, defaults: defaults)
    }

    private func saveHotkey(_ hotkey: Hotkey, key: String) {
        guard let data = try? JSONEncoder().encode(hotkey) else { return }
        defaults.set(data, forKey: key)
    }

    private static func loadHotkey(key: String, fallback: Hotkey, defaults: UserDefaults) -> Hotkey {
        guard let data = defaults.data(forKey: key),
              let hotkey = try? JSONDecoder().decode(Hotkey.self, from: data) else {
            return fallback
        }
        return hotkey
    }
}
