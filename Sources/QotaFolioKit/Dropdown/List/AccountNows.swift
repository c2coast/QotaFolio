import Foundation
import Kit
import QotaFolioModel

/// Each account's `AccountNow`, kept from one frame to the next. The list lays its cards out on every
/// hover and every frame of a carry, and the Engine runs only when the panel's minute or the
/// account's readings have moved since it last ran.
///
/// The store hands out the same readings until a poll changes them, so the comparison is of one
/// array with itself, and costs nothing until they differ.
@MainActor final class AccountNows {
    private struct Built {
        let readings: [Reading]
        let at: Date
        let zone: TimeZone
        let twelveHour: Bool
        let now: AccountNow?
    }

    private var built: [QotaFolioModel.AccountID: Built] = [:]

    func now(for id: QotaFolioModel.AccountID, readings: [Reading], words: TimeWords) -> AccountNow? {
        if let kept = built[id], kept.at == words.now, kept.zone == words.calendar.timeZone,
           kept.twelveHour == words.twelveHour, kept.readings == readings {
            return kept.now
        }
        let now = AccountNow(readings: readings, words: words)
        built[id] = Built(readings: readings, at: words.now, zone: words.calendar.timeZone, twelveHour: words.twelveHour, now: now)
        return now
    }
}
