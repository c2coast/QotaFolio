import Foundation

/// The sentences the app renders from an assessment, carried in the file so that a reader
/// does not have to render them again.
///
/// The words are Core's — they go through `qfLocalized` and a string catalog, and neither of
/// those belongs in a target a widget extension links. So Core writes them here once, and
/// `qota status` prints what the panel's rows say without linking a line of policy.
public nonisolated struct RecommendationSentences: Codable, Equatable, Sendable {
    /// One line per window: the number that is not already on the row.
    public let rows: [RecommendationRowText]

    public init(rows: [RecommendationRowText] = []) {
        self.rows = rows
    }

    public static let none = RecommendationSentences()

    func text(for account: AccountID, window: String) -> String? {
        rows.first { $0.account == account && $0.windowKey == window }?.text
    }
}

/// The right-hand text of one row, rendered.
public nonisolated struct RecommendationRowText: Codable, Equatable, Sendable {
    public let account: AccountID
    public let windowKey: String
    public let text: String

    public init(account: AccountID, windowKey: String, text: String) {
        self.account = account
        self.windowKey = windowKey
        self.text = text
    }
}

/// One window of one account, as the file states it.
///
/// The verdict is a string and not the enum, on purpose. A reader of this file — the `qota`
/// command, the widget, a shell script — must be able to decode a document written by a
/// QotaFolio that knows a verdict this one does not, and an enum makes that a decode failure
/// where a string makes it a word nobody matched.
public nonisolated struct RecommendedWindow: Codable, Equatable, Sendable {
    public let key: String
    /// The provider's own display name for a scoped limit; absent for an account-wide one.
    public let scope: String?
    public let usedPercent: Double
    public let resetsAt: Date?
    /// Where the window lands, or absent because no number inside the range would be honest.
    public let landingPercent: Double?
    public let lowPercent: Double?
    public let highPercent: Double?
    /// `onCourse` · `cuttingItClose` · `runningOut` · `spent` · `silent`.
    public let verdict: String
    /// Why the app is saying nothing about this window, when it is.
    public let silence: String?
    /// When the projected path reaches the limit, if it does and an instant can be named.
    public let limitAt: Date?
    /// The right-hand text a person reads on this row.
    public let detail: String?

    public init(
        key: String,
        scope: String?,
        usedPercent: Double,
        resetsAt: Date?,
        landingPercent: Double?,
        lowPercent: Double?,
        highPercent: Double?,
        verdict: String,
        silence: String?,
        limitAt: Date?,
        detail: String?
    ) {
        self.key = key
        self.scope = scope
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.landingPercent = landingPercent
        self.lowPercent = lowPercent
        self.highPercent = highPercent
        self.verdict = verdict
        self.silence = silence
        self.limitAt = limitAt
        self.detail = detail
    }
}

/// One account, as the file states it.
public nonisolated struct RecommendedAccount: Codable, Equatable, Sendable, Identifiable {
    public let id: AccountID
    public let name: String
    public let provider: AccountProvider
    public let order: Int
    /// Percentage points left in the account's own windows.
    public let weeklyRemainingPercent: Double?
    public let sessionRemainingPercent: Double?
    /// Whether this account can serve right now, and when it comes back if not.
    public let isAvailable: Bool
    public let returnsAt: Date?
    public let windows: [RecommendedWindow]

    public init(
        id: AccountID,
        name: String,
        provider: AccountProvider,
        order: Int,
        weeklyRemainingPercent: Double?,
        sessionRemainingPercent: Double?,
        isAvailable: Bool,
        returnsAt: Date?,
        windows: [RecommendedWindow]
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.order = order
        self.weeklyRemainingPercent = weeklyRemainingPercent
        self.sessionRemainingPercent = sessionRemainingPercent
        self.isAvailable = isAvailable
        self.returnsAt = returnsAt
        self.windows = windows
    }
}

/// `recommendation.json`: the fleet's current reading, and the words for it.
///
/// Written on every assessment, on the snapshot book's clock. Read by the `qota` command, by
/// the widget and by the Control — three readers outside this process.
///
/// **This is the file's own shape and not the brain's.** `FleetAssessment` carries bands,
/// evidence and an activity profile, and it will carry more; a reader outside this app needs
/// the account, the window, the verdict and the sentence, and needs them to keep decoding
/// when the brain grows. So the document is mapped from the assessment rather than being it.
public nonisolated struct RecommendationDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    /// Generous by an order of magnitude against five accounts with sentences, and small
    /// enough that a reader can refuse anything larger before allocating it.
    public static let maximumBytes = 64 * 1024

    public let schemaVersion: UInt16
    /// The snapshot book's clock, so the file says when the numbers were true rather than
    /// when they were written.
    public let generatedAt: Date
    /// In panel order.
    public let accounts: [RecommendedAccount]
    /// The earliest instant this answer could change without a poll.
    public let nextReviewAt: Date?
    public let sentences: RecommendationSentences

    public init(
        schemaVersion: UInt16 = RecommendationDocument.currentSchemaVersion,
        generatedAt: Date,
        accounts: [RecommendedAccount],
        nextReviewAt: Date?,
        sentences: RecommendationSentences = .none
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.accounts = accounts
        self.nextReviewAt = nextReviewAt
        self.sentences = sentences
    }

    /// The document the app writes, from the assessment it just made.
    public init(assessment: FleetAssessment, sentences: RecommendationSentences = .none) {
        self.init(
            generatedAt: assessment.generatedAt,
            accounts: assessment.accounts.map { row in
                RecommendedAccount(
                    id: row.id,
                    name: row.account.name,
                    provider: row.account.provider,
                    order: row.account.order,
                    weeklyRemainingPercent: row.weeklyRemainingPercent,
                    sessionRemainingPercent: row.sessionRemainingPercent,
                    isAvailable: row.isAvailable,
                    returnsAt: row.returnsAt,
                    windows: row.windows.map { window in
                        RecommendedWindow(
                            key: window.windowKey,
                            scope: window.scope,
                            usedPercent: window.usedPercent,
                            resetsAt: window.resetsAt,
                            landingPercent: window.landingPercent,
                            lowPercent: window.outerBand?.lowPercent,
                            highPercent: window.outerBand?.highPercent,
                            verdict: window.verdict.name,
                            silence: window.verdict.silenceName,
                            limitAt: window.verdict.limitInstant,
                            detail: sentences.text(for: row.id, window: window.windowKey)
                        )
                    }
                )
            },
            nextReviewAt: assessment.nextReviewAt,
            sentences: sentences
        )
    }
}

public nonisolated enum RecommendationCodec {
    /// The bytes to write, or `nil` when there are none this build would agree to read back.
    public static func encode(_ document: RecommendationDocument) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(document),
              data.count <= RecommendationDocument.maximumBytes else { return nil }
        return data
    }

    /// A verdict on bytes that were read in full: either this build can use them, or it
    /// cannot and reading them again will not change that.
    public static func decode(_ data: Data) -> RecommendationDocument? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(RecommendationDocument.self, from: data),
              document.schemaVersion == RecommendationDocument.currentSchemaVersion else {
            return nil
        }
        return document
    }
}
