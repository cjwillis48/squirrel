import AppKit
import SwiftUI

/// A button that, when clicked, captures the next modifier+key combo and saves it.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    var defaultHotkey: Hotkey
    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { isRecording.toggle() }) {
                Text(isRecording ? "Press a shortcut…" : hotkey.displayString)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 120, alignment: .center)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isRecording ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isRecording ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .background(
                HotkeyCaptureView(isRecording: $isRecording) { newHotkey in
                    hotkey = newHotkey
                    isRecording = false
                }
            )

            if hotkey != defaultHotkey {
                Button("Reset") {
                    hotkey = defaultHotkey
                }
                .controlSize(.small)
            }
        }
    }
}

/// Hosts a custom NSView that captures keyboard events when isRecording is true.
private struct HotkeyCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onCapture: (Hotkey) -> Void

    func makeNSView(context: Context) -> CaptureNSView {
        let view = CaptureNSView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: CaptureNSView, context: Context) {
        nsView.isRecording = isRecording
        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

private final class CaptureNSView: NSView {
    var isRecording = false
    var onCapture: ((Hotkey) -> Void)?

    override var acceptsFirstResponder: Bool { isRecording }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        if let hotkey = Hotkey(event: event) {
            onCapture?(hotkey)
        } else {
            NSSound.beep()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        if let hotkey = Hotkey(event: event) {
            onCapture?(hotkey)
            return true
        }
        return false
    }
}
