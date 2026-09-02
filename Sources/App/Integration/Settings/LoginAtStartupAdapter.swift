import AppKit
import Observation
import ServiceManagement
import SwiftUI
import QotaFolioKit

nonisolated enum LoginItemServiceStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

@MainActor
protocol LoginItemServiceSource: AnyObject {
    var status: LoginItemServiceStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

@MainActor
final class MainAppLoginItemServiceSource: LoginItemServiceSource {
    private let service: SMAppService

    init() {
        service = .mainApp
    }

    var status: LoginItemServiceStatus {
        switch service.status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notFound
        @unknown default:
            .notFound
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor @Observable
final class SMAppServiceLoginAtStartupAdapter: LoginAtStartupControlling {
    private(set) var status: LoginAtStartupStatus
    private(set) var failureMessage: String?
    private(set) var externalStatusChangeCount = 0

    @ObservationIgnored private let source: any LoginItemServiceSource

    init(source: any LoginItemServiceSource) {
        self.source = source
        status = Self.map(source.status)
        failureMessage = nil

        // Open at Login is approved, denied, or switched off in System Settings,
        // where this app is not running. Returning to the app is the moment its
        // answer can have changed, so the app asks the system again instead of
        // showing what it last wrote. The observation lives as long as this
        // controller, which lives as long as the process.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reconcileWithSystemRegistration()
            }
        }
    }

    convenience init() {
        self.init(source: MainAppLoginItemServiceSource())
    }

    func enabledBinding() -> Binding<Bool> {
        Binding(
            get: { self.status == .enabled },
            set: { self.setEnabled($0) }
        )
    }

    func refresh() {
        status = Self.map(source.status)
    }

    func openLoginItemsSettings() {
        source.openSystemSettingsLoginItems()
    }

    /// Re-reads the real registration and adopts the system's answer.
    ///
    /// A failure message describes a write this app attempted. The system has since
    /// given a different answer, so the message describes a state that no longer
    /// exists and is dropped with it.
    private func reconcileWithSystemRegistration() {
        let observed = Self.map(source.status)
        guard observed != status else { return }

        status = observed
        failureMessage = nil
        externalStatusChangeCount += 1
    }

    private func setEnabled(_ enabled: Bool) {
        failureMessage = nil
        applyRegistration(enabled)
        refresh()
    }

    private func applyRegistration(_ enabled: Bool) {
        do {
            if enabled {
                try source.register()
            } else {
                try source.unregister()
            }
        } catch {
            failureMessage = enabled
                ? "QotaFolio couldn't enable Open at Login. Try again or open Login Items settings."
                : "QotaFolio couldn't disable Open at Login. Try again or open Login Items settings."
        }
    }

    private nonisolated static func map(
        _ status: LoginItemServiceStatus
    ) -> LoginAtStartupStatus {
        switch status {
        case .notRegistered, .notFound:
            .disabled
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        }
    }
}
