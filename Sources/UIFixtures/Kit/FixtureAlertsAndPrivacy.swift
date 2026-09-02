import Foundation
import QotaFolioCore
import QotaFolioKit

/// A notification centre that records instead of showing: what the deliverer asked and what it
/// delivered, with the system's answer scripted.
@MainActor public final class FixtureAlertCenter: AlertCenter {
    public nonisolated struct Delivery: Equatable, Sendable {
        public let id: String
        public let body: String
    }

    public var status: AlertAuthorization
    /// What the system will answer when asked; asking moves `status` accordingly.
    public var grantsWhenAsked: Bool
    public private(set) var authorizationRequests = 0
    public private(set) var deliveries: [Delivery] = []
    /// When set, every delivery fails with this error — the system refusing a request.
    public var deliveryFailure: (any Error)?
    /// Printed on every delivery when set: the lab's way of seeing an alert without a dialog.
    public var printsDeliveries = false

    public init(status: AlertAuthorization = .notDetermined, grantsWhenAsked: Bool = true) {
        self.status = status
        self.grantsWhenAsked = grantsWhenAsked
    }

    public func authorization() async -> AlertAuthorization { status }

    public func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        status = grantsWhenAsked ? .authorized : .denied
        return grantsWhenAsked
    }

    public func deliver(id: String, body: String) async throws {
        if let deliveryFailure { throw deliveryFailure }
        deliveries.append(Delivery(id: id, body: body))
        if printsDeliveries {
            print("QF_ALERT id=\(id) body=\(body)")
            fflush(stdout)
        }
    }
}

/// A screen-watcher probe whose answer is set by hand.
@MainActor public final class FixtureScreenWatcherProbe: ScreenWatcherProbing {
    public var isAvailable: Bool
    public var watched: Bool

    public init(isAvailable: Bool = true, watched: Bool = false) {
        self.isAvailable = isAvailable
        self.watched = watched
    }

    /// How many times the app has asked. The count is what proves the poll stops when its
    /// answer would be discarded.
    public private(set) var asks = 0

    public func isScreenWatched() -> Bool {
        asks += 1
        return watched
    }
}
