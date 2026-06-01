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
            Image(systemName: state.recordingState.symbolName)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
        }
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
