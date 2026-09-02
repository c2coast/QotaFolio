import Foundation
import Observation
import SwiftUI
import QotaFolioKit

@MainActor
protocol SettingsIntegrationObservation: AnyObject {
    func cancel()
}

@MainActor
protocol SettingsUpdaterSource: AnyObject {
    var updateCheckAvailability: UpdateCheckAvailability { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }

    func checkForUpdates()
    func observeStateChanges(
        _ handler: @MainActor @Sendable @escaping () -> Void
    ) -> any SettingsIntegrationObservation
}

@MainActor @Observable
final class SparkleSettingsAdapter: NSObject, SettingsUpdating {
    private(set) var updateCheckAvailability: UpdateCheckAvailability
    private(set) var automaticallyChecksForUpdates: Bool
    private(set) var automaticallyDownloadsUpdates: Bool

    @ObservationIgnored private let source: any SettingsUpdaterSource
    @ObservationIgnored private var observation: (any SettingsIntegrationObservation)?
    @ObservationIgnored private var observationIsCancelled = false

    init(source: any SettingsUpdaterSource) {
        self.source = source
        updateCheckAvailability = source.updateCheckAvailability
        automaticallyChecksForUpdates = source.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = source.automaticallyDownloadsUpdates
        super.init()
        observation = source.observeStateChanges { [weak self] in
            guard let self, !self.observationIsCancelled else { return }
            self.refresh()
        }
    }

    func checksBinding() -> Binding<Bool> {
        Binding(
            get: { self.automaticallyChecksForUpdates },
            set: { newValue in
                self.source.automaticallyChecksForUpdates = newValue
                self.refresh()
            }
        )
    }

    func downloadsBinding() -> Binding<Bool> {
        Binding(
            get: { self.automaticallyDownloadsUpdates },
            set: { newValue in
                self.source.automaticallyDownloadsUpdates = newValue
                self.refresh()
            }
        )
    }

    func checkForUpdates() {
        refresh()
        guard updateCheckAvailability == .ready else { return }
        source.checkForUpdates()
        refresh()
    }

    func cancelObservation() {
        observationIsCancelled = true
        observation?.cancel()
        observation = nil
    }

    private func refresh() {
        let nextAvailability = source.updateCheckAvailability
        let nextChecks = source.automaticallyChecksForUpdates
        let nextDownloads = source.automaticallyDownloadsUpdates

        if updateCheckAvailability != nextAvailability {
            updateCheckAvailability = nextAvailability
        }
        if automaticallyChecksForUpdates != nextChecks {
            automaticallyChecksForUpdates = nextChecks
        }
        if automaticallyDownloadsUpdates != nextDownloads {
            automaticallyDownloadsUpdates = nextDownloads
        }
    }
}
