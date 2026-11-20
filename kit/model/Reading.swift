import Foundation

/// Which account a reading belongs to. Only the provider's own id, never a name or an address.
public struct AccountID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// What one poll of an account said: every limit, and when those numbers were true.
public struct Reading: Hashable, Sendable {
    public let account: AccountID
    public let at: Date
    public let limits: [Limit]

    public init(account: AccountID, at: Date, limits: [Limit]) {
        self.account = account
        self.at = at
        self.limits = limits
    }

    public func limit(_ kind: Limit.Kind) -> Limit? {
        limits.first { $0.kind == kind }
    }
}
