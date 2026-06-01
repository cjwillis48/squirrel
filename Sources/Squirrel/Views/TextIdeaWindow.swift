import AppKit
import SwiftUI
import SquirrelCore

@MainActor
final class TextIdeaWindowController: NSObject {
    static let shared = TextIdeaWindowController()

    private var window: NSWindow?

    func showOrFocus() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        controller.title = "New idea"
        controller.titlebarAppearsTransparent = true
        controller.isMovableByWindowBackground = true
        controller.center()
        controller.isReleasedWhenClosed = false
        controller.level = .floating
        controller.delegate = self

        let hosting = NSHostingController(
            rootView: TextIdeaView(onSubmit: { [weak self] text in
                self?.submit(text: text)
            }, onCancel: { [weak self] in
                self?.window?.close()
            })
            .environmentObject(AppState.shared)
        )
        controller.contentViewController = hosting

        NSApp.activate(ignoringOtherApps: true)
        controller.makeKeyAndOrderFront(nil)
        self.window = controller
    }

    private func submit(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        window?.close()
        Task { await AppState.shared.submitTypedIdea(text: trimmed) }
    }
}

extension TextIdeaWindowController: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.window = nil }
    }
}

private struct TextIdeaView: View {
    @EnvironmentObject private var state: AppState
    @State private var text: String = ""
    @FocusState private var focused: Bool

    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "leaf.fill")
                    .foregroundStyle(.tint)
                Text("Stash an idea in the forest")
                    .font(.headline)
                Spacer()
                Text(targetHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            TextEditor(text: $text)
                .font(.body)
                .focused($focused)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2))
                )
                .frame(minHeight: 100)

            HStack {
                Text("⌘↩ to save · Esc to cancel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Stash idea") {
                    onSubmit(text)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 200)
        .onAppear {
            // Defer so the NSWindow has fully presented before claiming first responder.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focused = true
            }
        }
    }

    private var targetHint: String {
        "→ " + state.preferences.forestPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
