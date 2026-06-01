import Foundation

enum RecordingState: Equatable {
    case idle
    case recording
    case transcribing
    case summarizing
    case error(String)

    var symbolName: String {
        switch self {
        case .idle: return "leaf.fill"
        case .recording: return "waveform.circle.fill"
        case .transcribing: return "text.bubble.fill"
        case .summarizing: return "sparkles"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var statusLabel: String {
        switch self {
        case .idle: return "Idle"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .summarizing: return "Summarizing…"
        case .error(let message): return "Error: \(message)"
        }
    }

    var isBusy: Bool {
        switch self {
        case .idle, .error: return false
        default: return true
        }
    }
}

enum RecordingMode: String, CaseIterable, Identifiable {
    case toggle
    case pushToTalk

    var id: String { rawValue }

    var label: String {
        switch self {
        case .toggle: return "Press to start/stop"
        case .pushToTalk: return "Hold to record"
        }
    }
}
