import Foundation
import Observation
import UserNotifications
import QotaFolioCore

/// Where the person stands with the system on notifications from this app.
public nonisolated enum AlertAuthorization: Equatable, Sendable {
    /// The system has never been asked. It is asked the first time an alert is due.
    case notDetermined
    case authorized
    case denied
    case unknown
}

/// The door to the system's notifications, narrow enough for a fixture to stand in for it.
@MainActor public protocol AlertCenter: AnyObject {
    func authorization() async -> AlertAuthorization
    /// Puts the system's question to the person. The dialog is the system's; the answer is
    /// whether alerts may be shown.
    func requestAuthorization() async -> Bool
    /// Shows one alert. `id` is the alert's stable key, so the system too sees one per key.
    func deliver(id: String, body: String) async throws
}

/// `UNUserNotificationCenter`, as the app uses it: plain banners with a sentence in them.
/// No categories, no actions, no sound — the app shows.
@MainActor public final class UserNotificationAlertCenter: NSObject, AlertCenter, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    public override init() {
        super.init()
        // A menu-bar app can be the active app when an alert lands; without a delegate the
        // system would then drop the banner on the floor.
        center.delegate = self
    }

    public func authorization() async -> AlertAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        @unknown default: return .unknown
        }
    }

    public func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert])) ?? false
    }

    public func deliver(id: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.body = body
        content.interruptionLevel = .active
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

/// Delivers the brain's alerts as the assessment publishes them: one delivery per key, only
/// for accounts the person wants to hear about, and only after the system has been asked —
/// the first time an alert is due, never at launch.
///
/// The store's review wake re-assesses on the minute a reset lands, so a fresh-window alert
/// arrives on the minute too, through this same observation.
@MainActor @Observable public final class AlertDeliverer {
    /// Where the person stands with the system, as last read. Settings shows it.
    public private(set) var authorization: AlertAuthorization = .unknown

    @ObservationIgnored private let store: any AccountsStoring
    @ObservationIgnored private let preferences: AlertPreferences
    @ObservationIgnored private let center: any AlertCenter
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let style: SentenceStyle
    /// Keys already delivered or deliberately skipped, newest last, capped.
    @ObservationIgnored private var seenKeys: [String]
    @ObservationIgnored private var seen: Set<String>
    @ObservationIgnored private var started = false
    @ObservationIgnored private var delivering = false
    @ObservationIgnored private var assessmentWaiting: FleetAssessment?

    public static let seenKeysKey = "alerts.delivered.v1"
    static let seenKeysCap = 200

    public init(
        store: any AccountsStoring,
        preferences: AlertPreferences,
        center: any AlertCenter,
        defaults: UserDefaults = .standard,
        style: SentenceStyle = SentenceStyle()
    ) {
        self.store = store
        self.preferences = preferences
        self.center = center
        self.defaults = defaults
        self.style = style
        seenKeys = defaults.stringArray(forKey: Self.seenKeysKey) ?? []
        seen = Set(seenKeys)
    }

    /// The keys this deliverer has handled, for whoever asks.
    public var deliveredKeys: Set<String> { seen }

    public func start() {
        guard !started else { return }
        started = true
        Task { @MainActor in await self.refreshAuthorization() }
        armObservation()
        if let assessment = store.assessment {
            Task { @MainActor in await self.deliver(from: assessment) }
        }
    }

    /// Reads the system's answer again — Settings asks when its window opens.
    public func refreshAuthorization() async {
        authorization = await center.authorization()
    }

    private func armObservation() {
        withObservationTracking {
            _ = store.assessment
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let assessment = self.store.assessment {
                    await self.deliver(from: assessment)
                }
                self.armObservation()
            }
        }
    }

    /// Delivers what is due in `assessment`. One pass at a time: a newer assessment arriving
    /// mid-pass waits and is delivered next, so no key is delivered twice.
    public func deliver(from assessment: FleetAssessment) async {
        if delivering {
            assessmentWaiting = assessment
            return
        }
        delivering = true
        defer {
            delivering = false
        }
        await deliverPass(assessment)
        while let next = assessmentWaiting {
            assessmentWaiting = nil
            await deliverPass(next)
        }
    }

    private func deliverPass(_ assessment: FleetAssessment) async {
        let unseen = assessment.alerts.filter { !seen.contains($0.key) }
        guard !unseen.isEmpty else { return }

        // An alert about an account the person switched off is not wanted, and not kept for
        // later either: switching alerts back on should not replay the past.
        let wanted = unseen.filter { preferences.isEnabled(for: $0.account) }
        for alert in unseen where !wanted.contains(where: { $0.key == alert.key }) {
            markSeen(alert.key)
        }
        guard !wanted.isEmpty else { return }

        // In context: the system is asked the first time there is something to show.
        var status = await center.authorization()
        if status == .notDetermined {
            status = await center.requestAuthorization() ? .authorized : .denied
        }
        authorization = status
        guard status == .authorized else { return }

        for alert in wanted {
            guard let body = AlertSentences.body(for: alert, in: assessment, style: style) else {
                markSeen(alert.key)
                continue
            }
            do {
                try await center.deliver(id: alert.key, body: body)
                markSeen(alert.key)
            } catch {
                // The system refused this one; the next assessment brings it round again.
            }
        }
    }

    private func markSeen(_ key: String) {
        guard !seen.contains(key) else { return }
        seen.insert(key)
        seenKeys.append(key)
        if seenKeys.count > Self.seenKeysCap {
            let surplus = seenKeys.count - Self.seenKeysCap
            for key in seenKeys.prefix(surplus) { seen.remove(key) }
            seenKeys.removeFirst(surplus)
        }
        defaults.set(seenKeys, forKey: Self.seenKeysKey)
    }
}
