import Foundation

/// Read-only snapshot of user-visible Squirrel configuration. Lives in a shared
/// UserDefaults suite so the menu bar app, CLI, and MCP server all see the same values.
///
/// We deliberately do NOT depend on AppKit/SwiftUI here so this can be used in pure
/// command-line targets.
public struct Configuration: Sendable {
    public static let suiteName = "com.charliewillis.squirrel.shared"

    public var forestPath: String
    public var summarizeWithClaude: Bool
    public var claudeModel: String
    public var whisperModel: String

    public init(
        forestPath: String,
        summarizeWithClaude: Bool,
        claudeModel: String,
        whisperModel: String
    ) {
        self.forestPath = forestPath
        self.summarizeWithClaude = summarizeWithClaude
        self.claudeModel = claudeModel
        self.whisperModel = whisperModel
    }

    public static func load() -> Configuration {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let defaultForestPath = (NSHomeDirectory() as NSString).appendingPathComponent("forest.md")
        return Configuration(
            forestPath: defaults.string(forKey: "forestPath") ?? defaultForestPath,
            summarizeWithClaude: defaults.object(forKey: "summarizeWithClaude") as? Bool ?? true,
            claudeModel: defaults.string(forKey: "claudeModel") ?? "claude-sonnet-4-6",
            whisperModel: defaults.string(forKey: "whisperModel") ?? "whisper-1"
        )
    }

    /// Persist this configuration to the shared UserDefaults suite.
    public func save() {
        let defaults = UserDefaults(suiteName: Self.suiteName) ?? .standard
        defaults.set(forestPath, forKey: "forestPath")
        defaults.set(summarizeWithClaude, forKey: "summarizeWithClaude")
        defaults.set(claudeModel, forKey: "claudeModel")
        defaults.set(whisperModel, forKey: "whisperModel")
    }

    public var anthropicKey: String? { KeychainStore.get(SecretKey.anthropic) }
    public var openAIKey: String? { KeychainStore.get(SecretKey.openAI) }
}
