import AppKit
import SwiftUI
import QotaFolioCore

/// The control that records the panel shortcut: click, type the combination, done.
///
/// While it records, a local key monitor takes the next keystroke — Escape cancels, Delete
/// clears, anything without ⌘, ⌃ or ⌥ is refused (a bare letter must never become a global
/// key) — and the registered hot key is held silent so the person can re-type the very
/// combination that is already set.
struct ShortcutRecorderView: View {
    let store: GlobalShortcutStore

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(buttonTitle)
                    .monospaced()
                    .frame(minWidth: 110)
            }
            .accessibilityIdentifier("qotafolio.settings.shortcut.record")
            .accessibilityLabel(accessibilityText)

            if store.shortcut != nil, !isRecording {
                Button {
                    store.set(nil)
                } label: {
                    Text(qfLocalized("settings.shortcut.clear", defaultValue: "Clear", comment: "Removes the panel shortcut."))
                }
                .accessibilityIdentifier("qotafolio.settings.shortcut.clear")
            }
        }
        .onDisappear { stopRecording() }
    }

    private var buttonTitle: String {
        if isRecording {
            return qfLocalized(
                "settings.shortcut.recording",
                defaultValue: "Type a shortcut…",
                comment: "Shown on the shortcut control while it waits for a keystroke."
            )
        }
        guard let shortcut = store.shortcut else {
            return qfLocalized(
                "settings.shortcut.none",
                defaultValue: "Record Shortcut",
                comment: "Shown on the shortcut control when no shortcut is set."
            )
        }
        return shortcut.display
    }

    private var accessibilityText: String {
        guard let shortcut = store.shortcut else {
            return qfLocalized(
                "settings.shortcut.ax.none",
                defaultValue: "No panel shortcut. Activate to record one.",
                comment: "VoiceOver label for the shortcut control when no shortcut is set."
            )
        }
        return qfLocalized(
            "settings.shortcut.ax.current",
            defaultValue: "Panel shortcut: \(shortcut.display). Activate to record a different one.",
            comment: "VoiceOver label for the shortcut control. The argument is the current key combination."
        )
    }

    private func startRecording() {
        isRecording = true
        store.setRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                switch event.keyCode {
                case UInt16(kVK_Escape):
                    stopRecording()
                case UInt16(kVK_Delete):
                    store.set(nil)
                    stopRecording()
                default:
                    guard let shortcut = GlobalShortcut(event: event) else {
                        NSSound.beep()
                        return
                    }
                    store.set(shortcut)
                    stopRecording()
                }
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        store.setRecording(false)
    }
}

import Carbon.HIToolbox
