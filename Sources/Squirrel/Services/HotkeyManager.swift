import AppKit
import ApplicationServices
import Carbon.HIToolbox

@MainActor
final class HotkeyManager {
    static let signature: UInt32 = 0x53515253 // "SQRS"

    var onToggle: (() -> Void)?
    var onPressDown: (() -> Void)?
    var onPressUp: (() -> Void)?
    var onTextEntry: (() -> Void)?
    /// Called with a user-facing message when a Carbon hotkey registration fails
    /// (usually `eventHotKeyExistsErr` because another app — Hammerspoon, Karabiner,
    /// Alfred, BetterTouchTool — has grabbed the same combo).
    var onRegistrationFailure: ((String) -> Void)?

    private var voiceHotkeyRef: EventHotKeyRef?
    private var textHotkeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var pttMonitorLocal: Any?
    private var pttMonitorGlobal: Any?
    private var mode: RecordingMode = .toggle
    private var isHolding = false
    /// Carbon HotKey re-fires `kEventHotKeyPressed` for every OS key-repeat tick
    /// while the user holds the combo. We listen for both Pressed and Released
    /// and track per-hotkey held state so the toggle/text callbacks fire exactly
    /// once per discrete physical press.
    private var voiceHotkeyDown = false
    private var textHotkeyDown = false

    private static let voiceHotKeyIDValue: UInt32 = 1
    private static let textHotKeyIDValue: UInt32 = 2

    init() {}

    deinit {
        // Carbon resources are released in stop(), called from app lifecycle.
    }

    private var voiceHotkey: Hotkey = .defaultVoice
    private var textHotkey: Hotkey = .defaultText

    func start(mode: RecordingMode, voiceHotkey: Hotkey, textHotkey: Hotkey) {
        stop()
        self.mode = mode
        self.voiceHotkey = voiceHotkey
        self.textHotkey = textHotkey
        installCarbonHandler()
        registerTextHotkey()
        switch mode {
        case .toggle:
            registerVoiceHotkey()
        case .pushToTalk:
            installPTTMonitor()
        }
    }

    func stop() {
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
        if let ref = voiceHotkeyRef {
            UnregisterEventHotKey(ref)
            voiceHotkeyRef = nil
        }
        if let ref = textHotkeyRef {
            UnregisterEventHotKey(ref)
            textHotkeyRef = nil
        }
        if let monitor = pttMonitorLocal {
            NSEvent.removeMonitor(monitor)
            pttMonitorLocal = nil
        }
        if let monitor = pttMonitorGlobal {
            NSEvent.removeMonitor(monitor)
            pttMonitorGlobal = nil
        }
        isHolding = false
        voiceHotkeyDown = false
        textHotkeyDown = false
    }

    // MARK: - Carbon shared handler

    private func installCarbonHandler() {
        guard eventHandler == nil else { return }
        var eventSpecs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            // Match soffes/HotKey's pattern exactly: invoke handlers synchronously
            // inside the Carbon callback and return `eventNotHandledErr` for
            // anything we don't own. Async dispatching from this callback
            // (or returning `noErr` for misses) leaves Carbon ambivalent about
            // suppression and the keystroke leaks through to the focused app's
            // responder chain, which NSBeeps on unhandled key equivalents.
            // Carbon HotKey events fire on the main thread, so MainActor.assumeIsolated
            // is safe.
            { _, eventRef, userData -> OSStatus in
                guard let userData, let eventRef else { return OSStatus(eventNotHandledErr) }
                var hkID = EventHotKeyID()
                let getStatus = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if getStatus != noErr { return getStatus }
                guard hkID.signature == HotkeyManager.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                let id = hkID.id
                let kind = GetEventKind(eventRef)
                return MainActor.assumeIsolated {
                    switch id {
                    case HotkeyManager.voiceHotKeyIDValue:
                        if kind == UInt32(kEventHotKeyPressed) {
                            // Carbon re-fires Pressed on every OS key-repeat tick;
                            // only act on the first one after a Released.
                            guard !manager.voiceHotkeyDown else { return noErr }
                            manager.voiceHotkeyDown = true
                            manager.onToggle?()
                        } else {
                            manager.voiceHotkeyDown = false
                        }
                        return noErr
                    case HotkeyManager.textHotKeyIDValue:
                        if kind == UInt32(kEventHotKeyPressed) {
                            guard !manager.textHotkeyDown else { return noErr }
                            manager.textHotkeyDown = true
                            manager.onTextEntry?()
                        } else {
                            manager.textHotkeyDown = false
                        }
                        return noErr
                    default:
                        return OSStatus(eventNotHandledErr)
                    }
                }
            },
            eventSpecs.count,
            &eventSpecs,
            selfPtr,
            &eventHandler
        )
    }

    // MARK: - Voice hotkey

    private func registerVoiceHotkey() {
        let hotKeyID = EventHotKeyID(signature: OSType(Self.signature), id: Self.voiceHotKeyIDValue)
        let status = RegisterEventHotKey(voiceHotkey.keyCode, voiceHotkey.modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &voiceHotkeyRef)
        if status != noErr {
            reportRegistrationFailure(label: "Voice", hotkey: voiceHotkey, status: status)
        }
    }

    // MARK: - Text-entry hotkey

    private func registerTextHotkey() {
        let hotKeyID = EventHotKeyID(signature: OSType(Self.signature), id: Self.textHotKeyIDValue)
        let status = RegisterEventHotKey(textHotkey.keyCode, textHotkey.modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &textHotkeyRef)
        if status != noErr {
            reportRegistrationFailure(label: "Text", hotkey: textHotkey, status: status)
        }
    }

    private func reportRegistrationFailure(label: String, hotkey: Hotkey, status: OSStatus) {
        let reason: String
        switch status {
        case OSStatus(eventHotKeyExistsErr):
            reason = "already grabbed by another app"
        case OSStatus(eventHotKeyInvalidErr):
            reason = "invalid combination"
        default:
            reason = "OSStatus \(status)"
        }
        let message = "\(label) hotkey \(hotkey.displayString) couldn't be registered — \(reason)."
        NSLog("[Squirrel] %@", message)
        onRegistrationFailure?(message)
    }

    // MARK: - Push-to-talk (NSEvent global monitor)

    private func installPTTMonitor() {
        // The global NSEvent monitor for keyboard events only fires if the app
        // is trusted for Accessibility. Without it, keyDown lands via the local
        // monitor when Squirrel is focused, but keyUp from any other app is
        // silently dropped — recording starts and never stops. The prompting
        // variant shows the system grant dialog inline if trust isn't set.
        // (Literal key string rather than `kAXTrustedCheckOptionPrompt` to avoid
        // Swift 6 strict-concurrency complaints about the C global var.)
        let opts = ["AXTrustedCheckOptionPrompt": kCFBooleanTrue] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            onRegistrationFailure?("Hold-to-record needs Accessibility permission. Enable Squirrel under System Settings ▸ Privacy & Security ▸ Accessibility, then relaunch Squirrel.")
        }

        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        let handler: (NSEvent) -> Void = { [weak self] event in
            self?.handlePTTEvent(event)
        }
        pttMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
        pttMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handler(event)
            return event
        }
    }

    private func handlePTTEvent(_ event: NSEvent) {
        let matchesKey = UInt32(event.keyCode) == voiceHotkey.keyCode
        let requiredFlags = nsFlags(from: voiceHotkey.modifiers)
        let hasModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .isSuperset(of: requiredFlags)

        switch event.type {
        case .keyDown:
            guard matchesKey, hasModifiers, !event.isARepeat, !isHolding else { return }
            isHolding = true
            onPressDown?()
        case .keyUp:
            guard matchesKey, isHolding else { return }
            isHolding = false
            onPressUp?()
        case .flagsChanged:
            if isHolding, !event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: requiredFlags) {
                isHolding = false
                onPressUp?()
            }
        default:
            break
        }
    }

    private func nsFlags(from carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }
}
