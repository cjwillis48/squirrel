import Foundation

public struct WhisperService: Sendable {
    public enum WhisperError: Error, LocalizedError {
        case missingKey
        case http(Int, String)
        case decoding

        public var errorDescription: String? {
            switch self {
            case .missingKey: return "OpenAI API key is not set."
            case .http(let code, let body): return "Whisper HTTP \(code): \(body)"
            case .decoding: return "Could not decode Whisper response."
            }
        }
    }

    public var apiKey: String?
    public var model: String

    public init(apiKey: String?, model: String = "whisper-1") {
        self.apiKey = apiKey
        self.model = model
    }

    public func transcribe(fileURL: URL) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else { throw WhisperError.missingKey }

        let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent

        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField(name: "model", value: model)
        appendField(name: "response_format", value: "json")
        // Pin to English so Whisper can't drift into Korean / Japanese / etc.
        // news-anchor sign-offs and outros on silent audio.
        appendField(name: "language", value: "en")
        // Deterministic decoding to minimize hallucination on borderline audio.
        appendField(name: "temperature", value: "0")
        // Intentionally no `prompt` — Whisper echoes its own bias prompt back
        // as the "transcript" on silent or near-silent input. The cure is
        // worse than the disease.

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WhisperError.decoding }
        if !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw WhisperError.http(http.statusCode, text)
        }

        struct Reply: Decodable { let text: String }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
