public nonisolated enum CredentialProbe: Equatable, Sendable {
    case present(revision: CredentialRevision, provider: AccountProvider)
    case absent
    case unreadable
}

public nonisolated enum ReconcileAction: Equatable, Sendable {
    case deleteOrphan(CredentialReference)
    case markConnected(AccountID, revision: CredentialRevision)
    case markNeedsReauthentication(AccountID, failedRevision: CredentialRevision?)
}

public nonisolated enum CredentialReconciler {
    public static func decide(
        records: [CredentialReconcileRecord],
        stored: Set<CredentialReference>,
        probes: [AccountID: CredentialProbe]
    ) -> [ReconcileAction] {
        let referenced = Set(records.map(\.reference))
        let orphanActions = stored
            .subtracting(referenced)
            .sorted { $0.rawValue < $1.rawValue }
            .map(ReconcileAction.deleteOrphan)

        var actions = orphanActions
        actions.reserveCapacity(orphanActions.count + records.count)

        for record in records {
            guard let probe = probes[record.accountID] else {
                assertionFailure("Credential reconciliation is missing a gathered probe.")
                continue
            }

            switch probe {
            case .present(let revision, let provider):
                if provider != record.provider {
                    actions.append(
                        .markNeedsReauthentication(record.accountID, failedRevision: nil)
                    )
                } else if let failedRevision = record.failedRevision,
                          failedRevision != revision {
                    actions.append(.markConnected(record.accountID, revision: revision))
                }
            case .absent:
                actions.append(
                    .markNeedsReauthentication(record.accountID, failedRevision: nil)
                )
            case .unreadable:
                break
            }
        }

        return actions
    }
}
