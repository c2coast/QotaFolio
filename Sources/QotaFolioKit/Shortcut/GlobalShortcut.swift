import AppKit
import Carbon.HIToolbox
import Observation
import QotaFolioCore

/// One keyboard shortcut, as Carbon speaks it and as a person reads it.
///
/// Carbon's `RegisterEventHotKey` is the one road to a system-wide key that needs no
/// Accessibility permission and works inside the sandbox — proven against the 26.5 SDK before
/// this file was written. The key code and modifier mask are stored in Carbon's own units so
/// registration is a pass-through.
public nonisolated struct GlobalShortcut: Hashable, Sendable {
    public let keyCode: UInt32
    /// Carbon's modifier mask: `cmdKey`, `optionKey`, `controlKey`, `shiftKey`.
    public let carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// ⌃⌥Q. Q for quota; the pair is free on a default macOS and collides with no system key.
    public static let standard = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_Q),
        carbonModifiers: UInt32(controlKey | optionKey)
    )

    /// The shortcut from a keystroke, or nil for one that must not become a global key: a bare
    /// letter would swallow typing everywhere, so at least one of ⌘, ⌃ or ⌥ is required.
    public init?(event: NSEvent) {
        var mask: UInt32 = 0
        if event.modifierFlags.contains(.command) { mask |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { mask |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { mask |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { mask |= UInt32(shiftKey) }
        guard mask & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: mask)
    }

    /// "⌃⌥Q" — modifiers in Apple's order, then the key's own name.
    public var display: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(for: keyCode)
    }

    /// The names a shortcut can be read back in. Positional (ANSI) names, which is what every
    /// shortcut UI on the Mac shows; a code with no name renders as its number, which still
    /// registers and still fires.
    private static let keyNames: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Backslash): "\\", UInt32(kVK_ANSI_Semicolon): ";",
        UInt32(kVK_ANSI_Quote): "'", UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Period): ".", UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_ANSI_Grave): "`",
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]

    static func keyName(for code: UInt32) -> String {
        keyNames[code] ?? "#\(code)"
    }
}

/// The one Carbon registration this app holds, and the action it fires.
///
/// One hot key, re-registered whenever the person records a different one, unregistered when
/// they clear it. Registration and the handler both sit on the event *dispatcher* target —
/// the funnel a hot-key event enters before any application target — which is the shape of
/// every implementation proven to fire in sandboxed menu-bar apps (MASShortcut, HotKey,
/// KeyboardShortcuts). The dispatcher is the main event loop's, so delivery is main-thread.
@MainActor public final class HotKeyCenter {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onPress: (@MainActor () -> Void)?
    /// While the recorder is capturing, the current key must not fire — the person may be
    /// re-typing the very combination that is registered.
    public var isSuspended = false

    public init() {}

    public func register(_ shortcut: GlobalShortcut?, onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        guard let shortcut else { return }
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x51_46_4F_4C) /* 'QFOL' */, id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            identifier,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        #if DEBUG
        print("QF_HOTKEY register keyCode=\(shortcut.keyCode) modifiers=\(shortcut.carbonModifiers) status=\(status)")
        #endif
        // A refusal means another app owns the combination system-wide. The recorder's owner
        // reads this and says so; registering nothing is the honest state until then.
        guard status == noErr else { return }
        hotKeyRef = ref
    }

    public func unregister() {
        register(nil, onPress: onPress ?? {})
        onPress = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                // The dispatcher target is serviced by the main event loop.
                MainActor.assumeIsolated {
                    Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue().fire()
                }
                return noErr
            },
            1,
            &spec,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &handlerRef
        )
    }

    private func fire() {
        guard !isSuspended else { return }
        #if DEBUG
        print("QF_HOTKEY fired")
        #endif
        onPress?()
    }
}

/// The person's shortcut for opening the panel: persisted, observable, and registered.
///
/// The default is ⌃⌥Q, present from the first launch. Recording a new key replaces the
/// registration at once; clearing it leaves the app with no global key until one is recorded
/// again. What the key does is the runtime's to say through `activate`.
@MainActor @Observable public final class GlobalShortcutStore {
    public static let defaultsKey = "settings.general.panelShortcut.v1"

    public private(set) var shortcut: GlobalShortcut?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let center: HotKeyCenter
    @ObservationIgnored private var action: (@MainActor () -> Void)?

    public init(defaults: UserDefaults = .standard, center: HotKeyCenter = HotKeyCenter()) {
        self.defaults = defaults
        self.center = center
        // Stored as [keyCode, modifiers]; an empty array is a cleared shortcut, and an absent
        // key is a person who has never touched the setting — the default.
        if let stored = defaults.array(forKey: Self.defaultsKey) as? [Int] {
            shortcut = stored.count == 2
                ? GlobalShortcut(keyCode: UInt32(stored[0]), carbonModifiers: UInt32(stored[1]))
                : nil
        } else {
            shortcut = .standard
        }
    }

    /// Registers the current shortcut with the action it fires, and keeps registration
    /// following every later change.
    public func activate(onPress: @escaping @MainActor () -> Void) {
        action = onPress
        applyRegistration()
    }

    public func deactivate() {
        action = nil
        center.unregister()
    }

    public func set(_ new: GlobalShortcut?) {
        shortcut = new
        if let new {
            defaults.set([Int(new.keyCode), Int(new.carbonModifiers)], forKey: Self.defaultsKey)
        } else {
            defaults.set([Int](), forKey: Self.defaultsKey)
        }
        applyRegistration()
    }

    /// The recorder holds the key silent while it captures.
    public func setRecording(_ recording: Bool) {
        center.isSuspended = recording
    }

    private func applyRegistration() {
        guard let action else { return }
        center.register(shortcut, onPress: action)
    }
}
