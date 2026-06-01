import Foundation

/// Shared capture pipeline used by the menu bar app, the CLI, and the MCP server.
/// Takes raw idea text → optionally cleans it up via Claude → appends to forest.md.
public struct CaptureService: Sendable {
    public var forestPath: String
    public var summarizeWithClaude: Bool
    public var anthropicKey: String?
    public var claudeModel: String

    public init(
        forestPath: String,
        summarizeWithClaude: Bool,
        anthropicKey: String?,
        claudeModel: String
    ) {
        self.forestPath = forestPath
        self.summarizeWithClaude = summarizeWithClaude
        self.anthropicKey = anthropicKey
        self.claudeModel = claudeModel
    }

    public enum CaptureOutcome: Sendable {
        case captured(Idea, summarized: Bool)
        case empty
    }

    public func capture(transcript: String, durationSeconds: Double = 0, project: String? = nil) async throws -> CaptureOutcome {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        if Self.looksLikeWhisperHallucination(trimmed) { return .empty }

        var title = Self.fallbackTitle(from: trimmed)
        var bullets: [String] = []
        var summarized = false

        if summarizeWithClaude, let key = anthropicKey, !key.isEmpty {
            let anthropic = AnthropicService(apiKey: key, model: claudeModel)
            do {
                let summary = try await anthropic.summarize(transcript: trimmed)
                if summary.discard { return .empty }
                title = Self.clampTitle(summary.title)
                bullets = summary.bullets
                summarized = true
            } catch {
                // Non-fatal — fall through with the word-boundary fallback title.
            }
        }

        let idea = Idea(
            transcript: trimmed,
            title: title,
            bullets: bullets,
            forestPath: forestPath,
            durationSeconds: durationSeconds,
            project: project
        )

        let store = ForestStore(forestPath: forestPath)
        try store.append(idea: idea)
        return .captured(idea, summarized: summarized)
    }

    /// Title used when Claude summarization is off or unavailable. First few words
    /// of the transcript at a word boundary, with an ellipsis when truncated — never
    /// a mid-sentence/mid-word slice, which reads as a complete-but-cut-off thought
    /// to downstream consumers.
    static func fallbackTitle(from transcript: String, maxWords: Int = 6) -> String {
        let firstLine = transcript.split(separator: "\n").first.map(String.init) ?? transcript
        let words = firstLine.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return "Untitled idea" }
        if words.count <= maxWords { return words.joined(separator: " ") }
        return words.prefix(maxWords).joined(separator: " ") + "…"
    }

    /// Defensive clamp on the title Claude returns. The prompt asks for ≤8 words,
    /// but models occasionally overshoot; we cut at a word boundary and add an
    /// ellipsis rather than letting a paragraph-length title leak through.
    static func clampTitle(_ raw: String, maxWords: Int = 8, maxChars: Int = 60) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let underWordLimit = words.count <= maxWords
        let underCharLimit = trimmed.count <= maxChars
        if underWordLimit && underCharLimit { return trimmed }
        let wordClipped = words.prefix(maxWords).joined(separator: " ")
        if wordClipped.count <= maxChars { return wordClipped + "…" }
        // Still too long after the word cap — back up to the last whole word under maxChars.
        let charClipped = String(wordClipped.prefix(maxChars))
        if let lastSpace = charClipped.lastIndex(of: " ") {
            return String(charClipped[..<lastSpace]) + "…"
        }
        return charClipped + "…"
    }

    /// Whisper, especially on silent or near-silent audio, often emits stock filler phrases
    /// or single tokens. Drop these so they never reach the forest.
    static func looksLikeWhisperHallucination(_ text: String) -> Bool {
        let lower = text.lowercased()

        // Bracketed sound tags (e.g. [BLANK_AUDIO], [Music], [BGM]).
        if lower.hasPrefix("[") && lower.hasSuffix("]") { return true }

        // Single-word "transcripts" are almost always hallucinations on short silent audio.
        let alphaNumWordCount = lower
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .count
        if alphaNumWordCount <= 1 { return true }

        let canonicalized = lower.trimmingCharacters(in: CharacterSet.punctuationCharacters)
                                 .trimmingCharacters(in: .whitespaces)

        // Whole-string YouTube-outro filler that Whisper emits during silence.
        let knownPhrases: Set<String> = [
            "thank you",
            "thank you.",
            "thanks for watching",
            "thank you for watching",
            "thanks for watching.",
            "thank you for watching.",
            "thank you so much for watching",
            "if you enjoyed the video, please subscribe and like it",
            "please subscribe and like the video",
            "please subscribe",
            "subscribe",
            "like and subscribe",
            "bye",
            "okay",
            "beep"
        ]
        if knownPhrases.contains(canonicalized) { return true }

        // Substring signals that Whisper inserts on long silent stretches.
        // Anything that boils down to "subscribe / like / share my channel"
        // banter, or a copyright stamp, is a Whisper hallucination, not user
        // speech. Match leniently — variants are endless and humans don't say
        // them into their idea-capture mic.
        let substringSignals = [
            "subscribe to my channel",
            "subscribe to the channel",
            "like and subscribe",
            "don't forget to like",
            "don't forget to subscribe",
            "smash that like button",
            "hit the bell",
            "thanks for watching",
            "thank you for watching"
        ]
        for signal in substringSignals where lower.contains(signal) {
            return true
        }

        // Copyright watermark lines (e.g. "Copyright © 2018, New Thinking
        // Allowed Foundation") are training-data artifacts Whisper emits on
        // silent audio. Match "copyright" + a 4-digit year.
        if lower.contains("copyright") {
            let year = #/\b(19|20)\d{2}\b/#
            if (try? year.firstMatch(in: lower)) != nil { return true }
        }

        // Korean news-program sign-offs ("MBC 뉴스 …입니다", "KBS 뉴스 …", etc.)
        // are extremely common Whisper artifacts on silent audio.
        if text.contains("뉴스") && text.contains("입니다") { return true }

        return false
    }
}
