import AppKit
import Foundation

@MainActor public protocol CandidacyWake: AnyObject {
    func cancel()
}

@MainActor public protocol CandidacyScheduling: AnyObject {
    var now: Date { get }

    @discardableResult
    func schedule(
        at deadline: Date,
        tolerance: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any CandidacyWake
}

@MainActor public final class AppCandidacyScheduler: NSObject, CandidacyScheduling {
    public override init() {
        super.init()
    }

    public var now: Date { .now }

    @discardableResult
    public func schedule(
        at deadline: Date,
        tolerance: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any CandidacyWake {
        TimerCandidacyWake(deadline: deadline, tolerance: tolerance, action: action)
    }
}

@MainActor private final class TimerCandidacyWake: NSObject, CandidacyWake {
    private var timer: Timer?
    private var action: (@MainActor () -> Void)?

    init(
        deadline: Date,
        tolerance: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) {
        self.action = action
        super.init()

        let timer = Timer(
            fireAt: deadline,
            interval: 0,
            target: self,
            selector: #selector(fire),
            userInfo: nil,
            repeats: false
        )
        timer.tolerance = tolerance
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    public func cancel() {
        timer?.invalidate()
        timer = nil
        action = nil
    }

    @objc private func fire() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        let action = action
        self.action = nil
        action?()
    }

}
