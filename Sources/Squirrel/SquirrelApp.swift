import SwiftUI
import AppKit

@main
struct SquirrelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(state)
        } label: {
            // A dot rides on the icon whenever there are untagged ideas to triage —
            // the ambient pull signal. Composited into the template image rather
            // than added as a SwiftUI overlay, which gets clipped in the menu bar.
            Image(nsImage: Self.menuBarIcon(
                symbol: state.recordingState.symbolName,
                showDot: state.untaggedCount > 0
            ))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }

    /// Render the menu-bar glyph, optionally with a small badge dot in the top-right
    /// corner. Returned as a template image so the menu bar inverts it for light/dark
    /// automatically — the dot is baked into the same alpha mask as the glyph.
    private static func menuBarIcon(symbol: String, showDot: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Squirrel")
            .flatMap { $0.withSymbolConfiguration(config) } ?? NSImage()

        guard showDot else {
            base.isTemplate = true
            return base
        }

        let pad: CGFloat = 3 // headroom so the dot sits clear of the glyph
        let size = NSSize(width: base.size.width + pad, height: base.size.height + pad)
        let image = NSImage(size: size)
        image.lockFocus()
        base.draw(in: NSRect(x: 0, y: 0, width: base.size.width, height: base.size.height))
        let d: CGFloat = 4.5
        let dot = NSRect(x: size.width - d, y: size.height - d, width: d, height: d)
        NSColor.black.setFill() // colour ignored once isTemplate = true; becomes mask
        NSBezierPath(ovalIn: dot).fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppState.shared.start()
        // Proactively trigger the macOS microphone prompt so Squirrel is registered
        // in TCC and appears in System Settings ▸ Privacy & Security ▸ Microphone.
        AppState.shared.requestMicrophoneAccess()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.stop()
    }
}
