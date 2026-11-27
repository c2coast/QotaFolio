import Foundation
import Observation
import UserNotifications
import Kit
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

/// Delivers "a spent limit is back": when a new reading of an account finds a limit that had
/// reached 100 percent back, by its reset or by a banked reset. One delivery per event, only for
/// accounts the person wants to hear about, and only after the system has been asked — the first
/// time an alert is due, never at launch.
///
/// The event is Kit's `SpentLimitBack`, between the account's reading before and its newest, so
/// it is the account, the limit, the reset it was spent until and how it came back. Its key is
/// that, so the same event worked out again on the next poll is seen, and a week spent twice is
/// two events.
@MainActor @Observable public final class AlertDeliverer {
    /// Where the person stands with the system, as last read. Settings shows it.
    public private(set) var authorization: AlertAuthorization = .unknown

    @ObservationIgnored private let store: any AccountsStoring
    @ObservationIgnored private let catalog: any AccountCataloging
    @ObservationIgnored private let preferences: AlertPreferences
    @ObservationIgnored private let center: any AlertCenter
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let style: SentenceStyle
    /// Keys already delivered or deliberately skipped, newest last, capped.
    @ObservationIgnored private var seenKeys: [String]
    @ObservationIgnored private var seen: Set<String>
    @ObservationIgnored private var started = false
    @ObservationIgnored private var delivering = false
    @ObservationIgnored private var readingsWaiting: AccountReadings?

    public static let seenKeysKey = "alerts.delivered.v1"
    static let seenKeysCap = 200

    public init(
        store: any AccountsStoring,
        catalog: any AccountCataloging,
        preferences: AlertPreferences,
        center: any AlertCenter,
        defaults: UserDefaults = .standard,
        style: SentenceStyle = SentenceStyle()
    ) {
        self.store = store
        self.catalog = catalog
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
        let readings = store.readings
        Task { @MainActor in await self.deliver(from: readings) }
    }

    /// Reads the system's answer again — Settings asks when its window opens.
    public func refreshAuthorization() async {
        authorization = await center.authorization()
    }

    private func armObservation() {
        withObservationTracking {
            _ = store.readings
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.deliver(from: self.store.readings)
                self.armObservation()
            }
        }
    }

    /// Delivers what is due in `readings`. One pass at a time: newer readings arriving mid-pass
    /// wait and are delivered next, so no key is delivered twice.
    public func deliver(from readings: AccountReadings) async {
        if delivering {
            readingsWaiting = readings
            return
        }
        delivering = true
        defer {
            delivering = false
        }
        await deliverPass(readings)
        while let next = readingsWaiting {
            readingsWaiting = nil
            await deliverPass(next)
        }
    }

    private func deliverPass(_ readings: AccountReadings) async {
        let unseen = readings.flatMap { id, readings in
            readings.count < 2 ? [] : SpentLimitBack.between(readings[readings.count - 2], readings[readings.count - 1]).map { (id, $0) }
        }.filter { !seen.contains(Self.key($1)) }
        guard !unseen.isEmpty else { return }

        // An alert about an account the person switched off, or one the catalog no longer holds,
        // is not wanted, and not kept for later either: switching alerts back on should not
        // replay the past.
        let names = Dictionary(catalog.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let wanted = unseen.filter { id, _ in preferences.isEnabled(for: id) && names[id] != nil }
        for (_, back) in unseen where !wanted.contains(where: { $0.1 == back }) {
            markSeen(Self.key(back))
        }
        guard !wanted.isEmpty else { return }

        // In context: the system is asked the first time there is something to show.
        var status = await center.authorization()
        if status == .notDetermined {
            status = await center.requestAuthorization() ? .authorized : .denied
        }
        authorization = status
        guard status == .authorized else { return }

        var calendar = style.calendar
        calendar.timeZone = style.timeZone
        let words = TimeWords(calendar: calendar, twelveHour: style.locale.clockIsTwelveHour, now: Date())
        for (id, back) in wanted {
            let key = Self.key(back)
            do {
                try await center.deliver(id: key, body: back.sentence(account: names[id] ?? "", words: words))
                markSeen(key)
            } catch {
                // The system refused this one; the next readings bring it round again.
            }
        }
    }

    /// The event as a key: the account, the limit, the reset it was spent until, and how it
    /// came back.
    static func key(_ back: SpentLimitBack) -> String {
        let period = switch back.limit.period {
        case .week: "week"
        case .session: "session"
        case .other(let seconds): "\(Int(seconds))s"
        }
        let until = Int(back.spentUntil.instant.timeIntervalSince1970)
        return "back|\(back.account.rawValue)|\(back.limit.model ?? "")|\(period)|\(until)|\(back.how)"
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
