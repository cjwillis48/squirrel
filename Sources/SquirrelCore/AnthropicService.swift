import Foundation

public struct AnthropicService: Sendable {
    public enum AnthropicError: Error, LocalizedError {
        case missingKey
        case http(Int, String)
        case decoding

        public var errorDescription: String? {
            switch self {
            case .missingKey: return "Anthropic API key is not set."
            case .http(let code, let body): return "Anthropic HTTP \(code): \(body)"
            case .decoding: return "Could not decode Anthropic response."
            }
        }
    }

    public var apiKey: String?
    public var model: String

    public init(apiKey: String?, model: String = "claude-sonnet-4-6") {
        self.apiKey = apiKey
        self.model = model
    }

    public struct Summary: Sendable {
        public var title: String
        public var bullets: [String]
        /// True when Claude classified the transcript as a Whisper hallucination
        /// rather than real user speech. Caller should treat as empty capture.
        public var discard: Bool

        public init(title: String, bullets: [String], discard: Bool = false) {
            self.title = title
            self.bullets = bullets
            self.discard = discard
        }
    }

    public func summarize(transcript: String) async throws -> Summary {
        guard let apiKey, !apiKey.isEmpty else { throw AnthropicError.missingKey }

        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = """
        You turn a raw voice memo of an idea into a tight written entry for a personal "parking lot" markdown file.

        Default output (exact JSON shape, no preamble):
        {"title": "<<= 8 words, sentence case, no trailing period>>", "bullets": ["<1-4 bullets, each <= 20 words, action-oriented or specific>"]}

        Backstop: if the transcript clearly looks like a Whisper hallucination on silent audio — typical signs include YouTube-outro boilerplate ("like and subscribe", "thanks for watching"), copyright stamps ("Copyright © YYYY ..."), news-anchor sign-offs in any language (e.g. Korean MBC/KBS sign-offs ending in 입니다, English "I'm <name>, reporting"), or any content that reads like training-data filler rather than a person's casual idea — output instead exactly:
        {"discard": true}
        Don't second-guess obvious idea content; only discard when the transcript reads like model-generated filler.

        Be faithful to the speaker. Don't add ideas they didn't express. If the transcript is very short, return one bullet.
        """

        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 400,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": transcript]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AnthropicError.decoding }
        if !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AnthropicError.http(http.statusCode, text)
        }

        struct Reply: Decodable {
            struct Content: Decodable { let type: String; let text: String? }
            let content: [Content]
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let text = reply.content.compactMap { $0.text }.joined()

        return parseSummary(from: text, fallback: transcript)
    }

    private func parseSummary(from text: String, fallback: String) -> Summary {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped: String
        if trimmed.hasPrefix("```") {
            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            stripped = lines.dropFirst().dropLast().joined(separator: "\n")
        } else {
            stripped = trimmed
        }

        struct Parsed: Decodable {
            let title: String?
            let bullets: [String]?
            let discard: Bool?
        }

        if let data = stripped.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(Parsed.self, from: data) {
            if parsed.discard == true {
                return Summary(title: "", bullets: [], discard: true)
            }
            if let title = parsed.title, let bullets = parsed.bullets {
                return Summary(title: title, bullets: bullets)
            }
        }

        let firstSentence = fallback.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? "Idea"
        return Summary(title: String(firstSentence.prefix(60)), bullets: [fallback])
    }
}
