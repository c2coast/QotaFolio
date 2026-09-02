import Foundation

public nonisolated func renderableFlow(_ flow: AccountFlowPhase?) -> AccountFlowPhase? {
    switch flow {
    case .failed(.cancelled)?, .connected?:
        nil
    case let phase?:
        phase
    case nil:
        nil
    }
}

public nonisolated func occupancy(
    accountCount: Int,
    pendingReservationCount: Int
) -> Int {
    accountCount + pendingReservationCount
}
