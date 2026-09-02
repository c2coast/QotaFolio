import AppKit
import Observation
import SwiftUI
import QotaFolioCore

/// Asks whether anything is watching the screen right now.
@MainActor public protocol ScreenWatcherProbing: AnyObject {
    /// Whether this Mac can answer at all.
    var isAvailable: Bool { get }
    func isScreenWatched() -> Bool
}

/// The window server's own answer, asked through SkyLight's private
/// `CGSIsScreenWatcherPresent`, resolved at runtime.
///
/// macOS has no public way for an app to learn that its screen is being shared or recorded, and
/// `NSWindow.sharingType = .none` stopped excluding windows from capture on 15.4. This symbol is
/// the one signal there is. It is looked up by name and never linked, so a macOS that no longer
/// exports it leaves the automatic blanket absent — nothing crashes, and the manual toggle still
/// works. QotaFolio ships by Developer ID, where a private symbol is a risk the app carries
/// itself, not a rule it breaks.
public final class SkyLightScreenWatcherProbe: ScreenWatcherProbing {
    private typealias Function = @convention(c) () -> UInt8
    private let function: Function?

    public init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        var resolved: Function?
        if let handle = dlopen(path, RTLD_LAZY | RTLD_NOLOAD) ?? dlopen(path, RTLD_LAZY) {
            for name in ["SLSIsScreenWatcherPresent", "CGSIsScreenWatcherPresent"] {
                if let symbol = dlsym(handle, name) {
                    resolved = unsafeBitCast(symbol, to: Function.self)
                    break
                }
            }
        }
        function = resolved
    }

    public var isAvailable: Bool { function != nil }

    public func isScreenWatched() -> Bool {
        guard let function else { return false }
        return function() != 0
    }
}

/// The privacy blanket: whether account names are hidden and the batteries colourless.
///
/// Two reasons, one flag. The screen is being watched — shared, recorded, mirrored — and the
/// app keeps the person's account names and the tell-tale colours off it until the watching
/// ends; or the person asked for it by hand and it stays until they ask again. The strip and
/// the panel read `isBlanketed` and nothing else.
///
/// The automatic form can be switched off. A Mac that is worked on over Screen Sharing is
/// "watched" all day by its own owner, and a blanket that never lifts is not privacy, it is a
/// panel that has lost its names; the person decides.
@MainActor @Observable public final class ScreenPrivacy {
    /// Whether the window server reports a watcher right now.
    public private(set) var screenIsWatched: Bool
    private var hiddenByHand: Bool
    private var automaticEnabled: Bool

    /// Whether this Mac reports screen watching at all. When it does not, the automatic form
    /// of the blanket is simply absent and Settings says so.
    public let automaticFormIsAvailable: Bool

    @ObservationIgnored private let probe: any ScreenWatcherProbing
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var pollInterval: Duration = .seconds(2)

    public static let hideNamesKey = "settings.privacy.hideNames.v1"
    public static let automaticKey = "settings.privacy.hideNamesWhileShared.v1"

    public init(
        probe: any ScreenWatcherProbing = SkyLightScreenWatcherProbe(),
        defaults: UserDefaults = .standard
    ) {
        self.probe = probe
        self.defaults = defaults
        automaticFormIsAvailable = probe.isAvailable
        hiddenByHand = defaults.bool(forKey: Self.hideNamesKey)
        automaticEnabled = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
        screenIsWatched = probe.isAvailable && probe.isScreenWatched()
    }

    /// Whether a watched screen hides the names by itself. On by default.
    ///
    /// Switching it off stops the poll as well as the blanket. With it off, `isBlanketed`
    /// never consults `screenIsWatched`, so asking the window server every two seconds buys
    /// an answer nobody reads — and on a laptop those wakes are the difference between an
    /// app that sleeps with the machine and one that does not.
    public var hidesNamesWhileShared: Bool {
        get { automaticEnabled }
        set {
            guard newValue != automaticEnabled else { return }
            automaticEnabled = newValue
            defaults.set(newValue, forKey: Self.automaticKey)
            // On again: ask once now, so the blanket is right before the first tick.
            if newValue { refresh() }
            updatePolling()
        }
    }

    public func hidesNamesWhileSharedBinding() -> Binding<Bool> {
        Binding(
            get: { self.hidesNamesWhileShared },
            set: { self.hidesNamesWhileShared = $0 }
        )
    }

    /// The person's own switch. Persisted, so a Mac that is shared every morning stays covered.
    public var namesHiddenByHand: Bool {
        get { hiddenByHand }
        set {
            guard newValue != hiddenByHand else { return }
            hiddenByHand = newValue
            defaults.set(newValue, forKey: Self.hideNamesKey)
        }
    }

    /// What the strip and the panel read.
    public var isBlanketed: Bool { (automaticEnabled && screenIsWatched) || hiddenByHand }

    public func hideNamesBinding() -> Binding<Bool> {
        Binding(
            get: { self.namesHiddenByHand },
            set: { self.namesHiddenByHand = $0 }
        )
    }

    /// Asks the probe again, once.
    public func refresh() {
        guard probe.isAvailable else { return }
        let watched = probe.isScreenWatched()
        if watched != screenIsWatched {
            screenIsWatched = watched
        }
    }

    /// Keeps asking while the app runs: a light poll, because a screen share can begin from any
    /// app at any moment and macOS sends no word of it, and a look whenever another app comes
    /// to the front, which is where most shares are started.
    public func start(pollInterval: Duration = .seconds(2)) {
        guard automaticFormIsAvailable, !isStarted else { return }
        isStarted = true
        self.pollInterval = pollInterval
        refresh()
        updatePolling()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.automaticEnabled else { return }
                self.refresh()
            }
        })
    }

    /// Runs the poll exactly while its answer can change what somebody sees.
    ///
    /// The poll is the only way to learn that a screen share began — macOS sends no word of
    /// it, and a share can start with no app coming to the front (a remote connection to this
    /// very Mac is that case). So while the automatic blanket is on, the poll stays: slowing
    /// it or suspending it on screen sleep would trade a person's privacy for battery, and a
    /// share can be watched while the local screens are dark. While it is off, the poll is
    /// pure cost and does not run.
    private func updatePolling() {
        guard isStarted, automaticFormIsAvailable, automaticEnabled else {
            poll?.cancel()
            poll = nil
            return
        }
        guard poll == nil else { return }
        let interval = pollInterval
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval, tolerance: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    public func stop() {
        isStarted = false
        poll?.cancel()
        poll = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }
}
