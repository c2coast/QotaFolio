import Foundation

/// One Apple battery on the menu-bar strip: one account, in the panel's order.
///
/// The leftmost battery is the top card in the panel, and the user's drag reorders both.
/// Everything the strip draws about an account is here, and everything it says about an
/// account is derived from here — the drawing and the words never compute a number apart.
/// Every battery is drawn at full strength: the strip shows each account's level and says
/// nothing about which to use.
///
/// The percentages are whole numbers rather than fractions on purpose. The bar the eye
/// sees and the number VoiceOver reads are then literally the same number: a battery drawn
/// from 0.529 while the voice says "53 percent" is two answers to one question, and the
/// half-point it buys is 0.08 pt of a 15 pt fill.
public nonisolated struct BatteryCell: Hashable, Sendable, Identifiable {
  /// Why an account has nothing to draw.
  ///
  /// Each case is a different sentence to the user, because each has a different thing to
  /// do about it: wait, sign in, open the app, or fix the account.
  public enum NoReading: Hashable, Sendable {
    /// Connected, polling, and the first answer has not arrived yet.
    case waitingForFirstReading
    /// The grant has lapsed. The user signs in again.
    case needsSignIn
    /// The provider answered with nothing usable, and there is no earlier number to show.
    case unavailable
    /// The account cannot be polled at all until it is repaired.
    case setupIssue
  }

  /// What this account holds, in the strip's own vocabulary.
  ///
  /// It is always about what can be spent right now — the tighter of this session and the week —
  /// however the batteries happen to be drawn. This is what the words say, what decides the
  /// quiet outline, and what arms the wake for a reset. The drawing reads `figure(showing:)`
  /// instead, which is one window's own share, so a healthy session over a spent week draws a
  /// long bar and still says spent. The picture answers the question that was asked; the
  /// sentence beside it carries the one that was not.
  public enum State: Hashable, Sendable {
    /// Something to spend now.
    case reading
    /// A fifth or less of it. Apple turns a battery red under 20 %; so do we.
    case low
    /// Nothing spendable now, whatever either window still holds.
    case spent
    /// The outline alone, at the quiet weight. The tooltip line says why.
    case noReading(NoReading)
  }

  public let accountID: AccountID
  public var id: AccountID { accountID }
  /// The user's own name for the account, as it reads on the card.
  public let name: String
  /// The share of the week still held, 0…100.
  public let weeklyRemainingPercent: Int
  /// The share of this five-hour session still held, 0…100 — the session's own window, on its
  /// own budget.
  public let sessionRemainingPercent: Int
  public let state: State
  /// Whole minutes until a spent account can be used again, or nil when the provider has
  /// not said when that is.
  public let minutesToReturn: Int?

  public init(
    accountID: AccountID,
    name: String,
    weeklyRemainingPercent: Int,
    sessionRemainingPercent: Int,
    state: State,
    minutesToReturn: Int?
  ) {
    self.accountID = accountID
    self.name = name
    self.weeklyRemainingPercent = weeklyRemainingPercent
    self.sessionRemainingPercent = sessionRemainingPercent
    self.state = state
    self.minutesToReturn = minutesToReturn
  }

  /// What can actually be spent in the next minute: the tighter of the two windows, and the
  /// figure `state` and every sentence are written from. Nothing draws it.
  public var spendableNowPercent: Int {
    min(weeklyRemainingPercent, sessionRemainingPercent)
  }

  /// The length this battery is drawn to, for the quantity the person asked the strip to show.
  ///
  /// One window's own share, whichever was asked for, and nothing behind it. The other window
  /// stays in the words, where it can be said rather than guessed at from a second length.
  ///
  /// The rule itself is in the model, where the Control reaches it too, so the battery on the
  /// bar and the battery in Control Center can never be drawn to different quantities.
  public func figure(showing: StripShows) -> StripFigure {
    StripFigure(
      showing: showing,
      weeklyRemainingPercent: weeklyRemainingPercent,
      sessionRemainingPercent: sessionRemainingPercent
    )
  }
}

/// The whole menu-bar strip: the batteries, what VoiceOver reads, and what the tooltip says.
///
/// The three are made together from one set of facts, so the picture, the voice and the
/// hover can never disagree about an account.
public nonisolated struct StatusStripModel: Hashable, Sendable {
  /// The batteries, left to right, in the panel's order.
  ///
  /// Empty when the app has no account to draw at all — no accounts yet, a catalog it
  /// cannot read, or the first load still running. The strip still occupies the bar: the
  /// renderer draws one empty outline so there is something to click, and the two strings
  /// below say why it is empty.
  public let cells: [BatteryCell]
  /// One sentence per account, in strip order.
  public let accessibilityLabel: String
  /// One line per account, the same facts, with the reset times in Apple's short form.
  public let toolTip: String

  public init(cells: [BatteryCell], accessibilityLabel: String, toolTip: String) {
    self.cells = cells
    self.accessibilityLabel = accessibilityLabel
    self.toolTip = toolTip
  }
}

extension StatusStripModel {
  /// Apple turns a battery red under a fifth of its charge. The strip reads that off what
  /// can be spent right now — the tighter of the session and the week — because that is what
  /// a battery is read for.
  public static let lowRemainingPercent = 20

  /// The strip for one glance at the fleet.
  ///
  /// - Parameters:
  ///   - catalog: the accounts the strip draws, already in the panel's order and already
  ///     filtered to the ones the user keeps visible.
  ///   - loadState: whether the account list itself could be read.
  ///   - snapshots: the last reading per account.
  ///   - pollStatus: what the poller is doing per account.
  ///   - now: the instant the strip is drawn for; reset times are counted from it.
  public static func make(
    catalog: [AccountConfig],
    loadState: CatalogLoadState,
    snapshots: [AccountID: UsageSnapshot],
    pollStatus: [AccountID: AccountPollStatus],
    now: Date,
    namesHidden: Bool = false
  ) -> StatusStripModel {
    switch loadState {
    case .unreadable:
      let message = qfLocalized(
        "strip.catalogUnreadable",
        defaultValue: "QotaFolio can't read its saved accounts. Open QotaFolio for details.",
        comment: "Menu-bar strip words when the saved account list cannot be read. The retry lives in the panel, so this points there rather than offering one."
      )
      return saying(message)
    case .loading:
      let message = qfLocalized(
        "strip.loading",
        defaultValue: "Loading remaining quota.",
        comment: "Menu-bar strip words while the account list or the first reading is loading."
      )
      return saying(message)
    case .missing, .loaded:
      break
    }

    guard !catalog.isEmpty else {
      let message = qfLocalized(
        "strip.noAccounts",
        defaultValue: "No accounts configured. Open QotaFolio to add one.",
        comment: "Menu-bar strip words when no account has been added yet."
      )
      return saying(message)
    }

    let cells = catalog.map { account in
      cell(
        for: account,
        snapshot: snapshots[account.id],
        status: pollStatus[account.id],
        now: now,
        namesHidden: namesHidden
      )
    }

    return StatusStripModel(
      cells: cells,
      accessibilityLabel: spokenLabel(cells),
      toolTip: tooltip(cells)
    )
  }

  /// A strip with no battery to draw and one sentence to say.
  ///
  /// The item stays on the bar — an empty outline, something to click — and both the voice
  /// and the hover carry the same sentence, led by the app's name the way every spoken
  /// strip is.
  public static func saying(_ message: String) -> StatusStripModel {
    StatusStripModel(cells: [], accessibilityLabel: appSentence(message), toolTip: message)
  }

  /// The soonest reset among accounts that are spent, when every account is spent.
  ///
  /// Nil unless the whole fleet is spent: while one account can still be used, the strip
  /// says what each account holds, not when the others come back.
  static func soonestReturn(_ cells: [BatteryCell]) -> BatteryCell? {
    guard !cells.isEmpty, cells.allSatisfy({ $0.state == .spent }) else { return nil }
    return cells
      .filter { $0.minutesToReturn != nil }
      .min { ($0.minutesToReturn ?? 0) < ($1.minutesToReturn ?? 0) }
  }

  // MARK: - One account

  private static func cell(
    for account: AccountConfig,
    snapshot: UsageSnapshot?,
    status: AccountPollStatus?,
    now: Date,
    namesHidden: Bool
  ) -> BatteryCell {
    // The arithmetic is `AccountLevel`'s — one rule for the strip, the panel's card, the
    // Control, the widget and `qota`. The cell keeps only the strip's own vocabulary and its
    // whole-minutes countdown.
    let level = AccountLevel.make(account: account, snapshot: snapshot, status: status)

    let state: BatteryCell.State = switch level.state {
    case .reading: .reading
    case .low: .low
    case .spent: .spent
    case .noReading(.waitingForFirstReading): .noReading(.waitingForFirstReading)
    case .noReading(.needsSignIn): .noReading(.needsSignIn)
    case .noReading(.unavailable): .noReading(.unavailable)
    case .noReading(.setupIssue): .noReading(.setupIssue)
    }

    return BatteryCell(
      accountID: account.id,
      name: presentedAccountName(account, namesHidden: namesHidden),
      weeklyRemainingPercent: level.weeklyRemainingPercent,
      sessionRemainingPercent: level.sessionRemainingPercent,
      state: state,
      minutesToReturn: level.returnsAt.flatMap { minutes(until: $0, from: now) }
    )
  }

  /// Whole minutes from `now` to a reset, or nil when the one named has already passed.
  private static func minutes(until resetsAt: Date, from now: Date) -> Int? {
    let seconds = resetsAt.timeIntervalSince(now)
    guard seconds > 0 else { return nil }
    return Int((seconds / 60).rounded(.up))
  }

  // MARK: - What VoiceOver reads

  private static func spokenLabel(_ cells: [BatteryCell]) -> String {
    var sentences = [appName()]
    var remaining = cells

    if let soonest = soonestReturn(cells) {
      sentences.append(
        qfLocalized(
          "strip.ax.allSpent",
          defaultValue: "All accounts spent.",
          comment: "Spoken menu-bar strip sentence when no account has anything left to spend."
        )
      )
      sentences.append(
        qfLocalized(
          "strip.ax.soonestBack",
          defaultValue: "Soonest back: \(soonest.name) in \(spokenDuration(soonest.minutesToReturn ?? 0)).",
          comment: "Spoken menu-bar strip sentence naming the spent account that returns first and when."
        )
      )
      remaining.removeAll { $0.accountID == soonest.accountID }
    }

    sentences.append(contentsOf: remaining.map { spokenSentence(for: $0) })
    return sentences.joined(separator: " ")
  }

  /// One account's spoken sentence. Public because Spotlight's answer says the same words the
  /// strip does — one voice, two surfaces.
  public static func spokenSentence(for cell: BatteryCell) -> String {
    switch cell.state {
    case .reading, .low:
      return qfLocalized(
        "strip.ax.account",
        defaultValue: "\(cell.name): \(cell.sessionRemainingPercent) percent available now, \(cell.weeklyRemainingPercent) percent left this week.",
        comment: "Spoken menu-bar strip sentence for one account: what it lets you spend now, and what is left of its week."
      )
    case .spent:
      // The week is said even though nothing of it can be spent yet, because either window can
      // be the one drawn: a full-looking battery on an account that is spent for the next
      // 47 minutes has to have both facts in one sentence, or the two read as a disagreement.
      guard let minutes = cell.minutesToReturn else {
        return qfLocalized(
          "strip.ax.account.spent",
          defaultValue: "\(cell.name) spent. \(cell.weeklyRemainingPercent) percent left this week.",
          comment: "Spoken menu-bar strip sentence for a spent account whose provider named no return time, with what its week still holds."
        )
      }
      return qfLocalized(
        "strip.ax.account.spentUntil",
        defaultValue: "\(cell.name) spent, back in \(spokenDuration(minutes)). \(cell.weeklyRemainingPercent) percent left this week.",
        comment: "Spoken menu-bar strip sentence for a spent account, when it returns, and what its week still holds."
      )
    case .noReading(.waitingForFirstReading):
      return qfLocalized(
        "strip.ax.account.waiting",
        defaultValue: "\(cell.name) has no reading yet.",
        comment: "Spoken menu-bar strip sentence for an account whose first reading has not arrived."
      )
    case .noReading(.needsSignIn):
      return qfLocalized(
        "strip.ax.account.needsSignIn",
        defaultValue: "\(cell.name) needs sign-in.",
        comment: "Spoken menu-bar strip sentence for an account whose grant has lapsed."
      )
    case .noReading(.unavailable):
      return qfLocalized(
        "strip.ax.account.unavailable",
        defaultValue: "\(cell.name) has no reading.",
        comment: "Spoken menu-bar strip sentence for an account the provider answered nothing usable for."
      )
    case .noReading(.setupIssue):
      return qfLocalized(
        "strip.ax.account.setupIssue",
        defaultValue: "\(cell.name) has a setup issue.",
        comment: "Spoken menu-bar strip sentence for an account that cannot be polled until it is repaired."
      )
    }
  }

  // MARK: - What the tooltip says

  private static func tooltip(_ cells: [BatteryCell]) -> String {
    var lines: [String] = []
    var remaining = cells

    if let soonest = soonestReturn(cells) {
      lines.append(
        qfLocalized(
          "strip.tooltip.allSpent",
          defaultValue: "All accounts spent — \(soonest.name) is back in \(shortDuration(soonest.minutesToReturn ?? 0))",
          comment: "Menu-bar strip tooltip line when every account is spent, naming the one that returns first."
        )
      )
      remaining.removeAll { $0.accountID == soonest.accountID }
    }

    lines.append(contentsOf: remaining.map(tooltipLine))
    return lines.joined(separator: "\n")
  }

  private static func tooltipLine(_ cell: BatteryCell) -> String {
    switch cell.state {
    case .reading, .low:
      return qfLocalized(
        "strip.tooltip.account",
        defaultValue: "\(cell.name) \(cell.sessionRemainingPercent)% now · \(cell.weeklyRemainingPercent)% this week",
        comment: "Menu-bar strip tooltip line for one account, what it lets you spend now and what is left of its week."
      )
    case .spent:
      guard let minutes = cell.minutesToReturn else {
        return qfLocalized(
          "strip.tooltip.spent",
          defaultValue: "\(cell.name) spent · \(cell.weeklyRemainingPercent)% this week",
          comment: "Menu-bar strip tooltip line for a spent account whose provider named no return time, with what its week still holds."
        )
      }
      return qfLocalized(
        "strip.tooltip.spentUntil",
        defaultValue: "\(cell.name) spent · back in \(shortDuration(minutes)) · \(cell.weeklyRemainingPercent)% this week",
        comment: "Menu-bar strip tooltip line for a spent account, when it returns, and what its week still holds."
      )
    case .noReading(.waitingForFirstReading):
      return qfLocalized(
        "strip.tooltip.waiting",
        defaultValue: "\(cell.name) — waiting for its first reading",
        comment: "Menu-bar strip tooltip line for an account whose first reading has not arrived."
      )
    case .noReading(.needsSignIn):
      return qfLocalized(
        "strip.tooltip.needsSignIn",
        defaultValue: "\(cell.name) — needs sign-in",
        comment: "Menu-bar strip tooltip line for an account whose grant has lapsed."
      )
    case .noReading(.unavailable):
      return qfLocalized(
        "strip.tooltip.unavailable",
        defaultValue: "\(cell.name) — no reading",
        comment: "Menu-bar strip tooltip line for an account the provider answered nothing usable for."
      )
    case .noReading(.setupIssue):
      return qfLocalized(
        "strip.tooltip.setupIssue",
        defaultValue: "\(cell.name) — setup issue",
        comment: "Menu-bar strip tooltip line for an account that cannot be polled until it is repaired."
      )
    }
  }

  // MARK: - Words shared by both

  private static func appName() -> String {
    qfLocalized(
      "strip.ax.app",
      defaultValue: "QotaFolio.",
      comment: "The first thing VoiceOver reads on the menu-bar strip: the app it belongs to."
    )
  }

  private static func appSentence(_ sentence: String) -> String {
    "\(appName()) \(sentence)"
  }

  /// A duration as VoiceOver should say it: "47 minutes", "2 hours", "1 hour 30 minutes" — the
  /// panel's spelling, so the two surfaces never say one countdown two ways.
  static func spokenDuration(_ minutes: Int) -> String {
    SpokenDuration.spoken(minutes: minutes)
  }

  /// A duration in Apple's short form: "47m", "2h", "1h 30m".
  static func shortDuration(_ minutes: Int) -> String {
    let hours = max(0, minutes) / 60
    let rest = max(0, minutes) % 60
    if hours == 0 {
      return qfLocalized(
        "strip.time.short.minutes",
        defaultValue: "\(rest)m",
        comment: "A whole number of minutes in Apple's short form."
      )
    }
    if rest == 0 {
      return qfLocalized(
        "strip.time.short.hours",
        defaultValue: "\(hours)h",
        comment: "A whole number of hours in Apple's short form."
      )
    }
    return qfLocalized(
      "strip.time.short.hoursAndMinutes",
      defaultValue: "\(hours)h \(rest)m",
      comment: "Hours and minutes together in Apple's short form."
    )
  }
}
