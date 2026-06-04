import AppKit
import SwiftUI

/// A small, non-activating floating panel that briefly confirms a capture landed.
/// This is the deterministic, app-owned acknowledgment that replaced the
/// model-rendered "[🐿️ Squirrel] captured…" block — it can't be dropped by a
/// long assistant turn because no model is in the loop.
@MainActor
final class CaptureToastController: NSObject {
    static let shared = CaptureToastController()

    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    func show(title: String, duration: TimeInterval = 2.2) {
        // Reuse the existing panel if a capture lands while one is still up.
        dismissWorkItem?.cancel()

        let toast = ToastView(title: title)
        let hosting = NSHostingView(rootView: toast)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 64)

        let panel = self.panel ?? makePanel()
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func dismiss() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Animation completions fire on the main thread; hop back onto the
            // MainActor explicitly so the isolated `panel` access is sound.
            MainActor.assumeIsolated { self?.panel?.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    /// Top-right of the main screen, just below the menu bar — near the Squirrel
    /// menu-bar icon without trying to track its exact position.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - 16,
            y: visible.maxY - size.height - 12
        )
        panel.setFrameOrigin(origin)
    }
}

private struct ToastView: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Text("🐿️")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Captured")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
    }
}
