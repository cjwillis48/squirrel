import AVFoundation
import Foundation

@MainActor
final class AudioRecorder: NSObject, @preconcurrency AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private(set) var currentURL: URL?
    private(set) var startedAt: Date?
    /// Loudest sample observed during this recording (dBFS, negative number;
    /// 0 = max). Used to drop silent recordings before they ever reach Whisper.
    private var peakPower: Float = -160
    private var meterTimer: Timer?
    /// Anything below this peak is treated as effectively silent — Whisper
    /// would just hallucinate boilerplate on input this quiet. Real speech
    /// usually peaks at -25 dBFS or louder; -40 leaves a margin for soft
    /// speakers while still rejecting room-tone-only recordings.
    static let silenceThresholdDBFS: Float = -40

    enum RecorderError: LocalizedError {
        case permissionDenied
        case permissionRestricted
        case notRecording
        case startFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access is blocked. Open System Settings ▸ Privacy & Security ▸ Microphone and enable Squirrel."
            case .permissionRestricted:
                return "Microphone access is restricted on this Mac (parental controls or MDM)."
            case .notRecording: return "No active recording."
            case .startFailed: return "Couldn't start the audio recorder."
            }
        }
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func currentAuthorization() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func start() async throws -> URL {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await requestPermission()
            if !granted { throw RecorderError.permissionDenied }
        case .denied:
            throw RecorderError.permissionDenied
        case .restricted:
            throw RecorderError.permissionRestricted
        @unknown default:
            throw RecorderError.permissionDenied
        }

        let tempDir = FileManager.default.temporaryDirectory
        let filename = "squirrel-\(Int(Date().timeIntervalSince1970)).m4a"
        let url = tempDir.appendingPathComponent(filename)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw RecorderError.startFailed }

        self.recorder = recorder
        self.currentURL = url
        self.startedAt = Date()
        self.peakPower = -160

        // Sample the input level a few times a second so we know whether the
        // recording was actually silent before we burn a Whisper request on it.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let r = self.recorder else { return }
                r.updateMeters()
                let p = r.averagePower(forChannel: 0)
                if p > self.peakPower { self.peakPower = p }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer

        return url
    }

    @discardableResult
    func stop() throws -> (url: URL, duration: Double, peakPower: Float) {
        guard let recorder, let url = currentURL, let startedAt else {
            throw RecorderError.notRecording
        }
        recorder.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        let duration = Date().timeIntervalSince(startedAt)
        let peak = peakPower
        self.recorder = nil
        self.currentURL = nil
        self.startedAt = nil
        return (url, duration, peak)
    }

    var isRecording: Bool { recorder?.isRecording == true }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // No-op; we explicitly drive stop().
    }
}
