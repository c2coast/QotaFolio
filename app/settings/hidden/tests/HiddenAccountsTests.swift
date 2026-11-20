import Foundation
import QotaFolioModel
import Testing

/// What `qota status` keeps of a reading once the person has hidden an account, on three invented accounts.
struct HiddenAccountsTests {
    let first = AccountID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
    let second = AccountID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
    let third = AccountID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!)

    @Test("qota leaves out an account the person hid, and keeps the others in their order")
    func aHiddenAccountIsLeftOut() {
        let reading = SurfaceReading(accounts: [account(first, order: 0), account(second, order: 1), account(third, order: 2)], readAt: .distantPast)
        let hidden = HiddenAccounts.ids(stored: ["00000000-0000-0000-0000-00000000000b"])

        #expect(reading.hiding(hidden).accounts.map(\.id) == [first, third])
        #expect(reading.hiding([]).accounts.map(\.id) == [first, second, third])
    }

    @Test("The app stores the list as 1.0.0 did, lower-case ids in order, and reads back the same set")
    func theListKeepsTheShapeOfVersionOne() {
        let stored = HiddenAccounts.stored([third, first])

        #expect(stored == ["00000000-0000-0000-0000-00000000000a", "00000000-0000-0000-0000-00000000000c"])
        #expect(HiddenAccounts.ids(stored: stored) == [first, third])
        #expect(HiddenAccounts.ids(stored: ["not-an-id"]).isEmpty)
        #expect(HiddenAccounts.ids(stored: nil).isEmpty)
    }

    @Test("The key is the one version 1.0.0 wrote")
    func theKeyIsVersionOnes() {
        #expect(HiddenAccounts.key == "settings.accountVisibility.hiddenAccountIDs.v1")
    }

    private func account(_ id: AccountID, order: Int) -> SurfaceAccount {
        SurfaceAccount(
            id: id,
            name: "Account \(order)",
            provider: .anthropic,
            order: order,
            needsSignIn: false,
            level: AccountLevel.make(provider: .anthropic, needsSignIn: false, hasSetupIssue: false, isWaitingForFirstReading: true, snapshot: nil),
            windows: [],
            observedAt: nil,
            planName: nil
        )
    }
}
