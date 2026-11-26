import AppKit
import Foundation
import Observation
import ServiceManagement
import QotaFolioCore
import QotaFolioKit

/// This app's own login-item registration, as the removal needs to see it.
///
/// A protocol and not `SMAppService`, which is a concrete handle on Background Task Management:
/// every call on it reaches `backgroundtaskmanagementd` for real, and a test has no way to ask
/// for a different answer than the developer's own Mac gives. It is a seam for the reason
/// `home` is one — the code that deletes a user's things has to be testable without
/// deleting anybody's.
@MainActor
protocol LoginItemRegistration {
    func unregister() async throws
    /// True when the registration is still on this Mac.
    ///
    /// The question `unregister()`'s error cannot answer on its own: unregistering something that
    /// was never registered reports a failure and has nothing left to do.
    var isStillRegistered: Bool { get }
}

extension SMAppService: LoginItemRegistration {
    var isStillRegistered: Bool {
        switch status {
        case .notRegistered, .notFound: false
        default: true
        }
    }
}

/// What "Remove My Data" is wired to in a running app.
///
/// Three live objects and nothing else. Everything the removal actually deletes it deletes
/// itself, below.
@MainActor
struct UninstallSurroundings {
    /// Stops the poller and waits, bounded, for its tasks to end. Bounded because
    /// `AccountsStore` awaits its supervisors without a deadline of its own, and a removal
    /// that hangs is worse than a removal that reports one unfinished step.
    let stopPolling: @MainActor () async -> Void
    /// Clears the status item's saved position and takes it out of the menu bar. This runs
    /// before the preferences domain goes, or AppKit writes the position back on teardown.
    let removeStatusItem: @MainActor () -> Void
    /// Asks the app to quit, from the run loop rather than from inside a main-queue block.
    let quit: @MainActor () -> Void
}

/// "Remove My Data": five steps, in order, each reported honestly.
///
///   1. Stop polling.
///   2. Delete the app's own Keychain service, and end the grants those credentials held.
///      **This is the point of no return.**
///   3. Remove the app's files and the preferences domain: what this build writes outside the
///      sandbox, what version 1.0.0 left in its container, and the group's files.
///   4. Unregister the login item.
///   5. Show the app in Finder, say what is left to do in one sentence, quit.
///
/// **Every step is best-effort, including step 2**: a failure in one is recorded and the next
/// still runs, because stopping early would leave more behind than carrying on. Step 2 is the one
/// that cannot be taken *back*, and the confirmation sheet says so in the user's own terms before
/// it runs — but a step 2 that will not finish is a reason to keep going, not to stop. The
/// catalog, the Sparkle cache and the preferences domain are the user's data too, they are on a
/// different device from the Keychain, and abandoning them because `securityd` was slow would
/// leave strictly more behind and remove nothing extra.
///
/// **Every local step finishes before the removal waits on the network once.** Step 2 starts the
/// revokes and does not wait for them; they are joined at the end, under a deadline, after the
/// files and the login item are already gone. That ordering is the same rule the credential
/// delete follows one level down — nothing the user can see is ever behind a provider that may
/// not answer — applied to the whole removal rather than to one step of it.
///
/// Every byte the user cares about is gone after step 3. What is left is version 1.0.0's
/// container stub, whose `Data` folder links to the user's own Desktop, Documents and Downloads
/// and is never walked, and an app bundle the user drags to the Trash.
///
/// **Every step is bounded, because a quit is refused while this runs.**
/// `applicationShouldTerminate` answers `.terminateCancel` for the whole of `run()`, which is
/// right — Command-Q between the credential delete and the file delete would leave the removal
/// half-done with no way back — and it is the only refusal in the app. A refusal is only
/// defensible if you can say how long it lasts. Each of the five waits below is capped at
/// `TERMINATION_DRAIN_TIMEOUT`, so the answer is **ten seconds, worst case, every step timing
/// out**, against milliseconds in the ordinary case.
@MainActor @Observable
final class Uninstall: UninstallPresenting {
    private(set) var state: UninstallPresentationState = .idle

    @ObservationIgnored private let identity: AppIdentity
    /// The vault, named for the one thing this asks of it. Not the Keychain store underneath it:
    /// a refresh token is what ends a grant, and a refresh token never leaves the vault.
    @ObservationIgnored private let credentials: any OwnedGrantEnding
    @ObservationIgnored private let surroundings: UninstallSurroundings
    @ObservationIgnored private let loginItem: any LoginItemRegistration
    /// The home folder every owned place is under. Injectable for one reason: it is what lets the
    /// code that deletes a user's files be tested without deleting anybody's files.
    @ObservationIgnored private let home: URL
    @ObservationIgnored private var activeTask: Task<Void, Never>?

    init(
        identity: AppIdentity = .current,
        credentials: any OwnedGrantEnding,
        surroundings: UninstallSurroundings,
        loginItem: any LoginItemRegistration = SMAppService.mainApp,
        home: URL = .homeDirectory
    ) {
        self.identity = identity
        self.credentials = credentials
        self.surroundings = surroundings
        self.loginItem = loginItem
        self.home = home
    }

    /// True while the removal is running, so a quit does not race it past step 2.
    var isRemoving: Bool { state == .removing }

    // MARK: - What the sheet does

    func requestConfirmation() {
        guard activeTask == nil else { return }
        switch state {
        case .idle:
            state = .confirmation
        case .confirmation, .removing, .finished:
            break
        }
    }

    func cancelConfirmation() {
        guard activeTask == nil, state == .confirmation else { return }
        state = .idle
    }

    func confirmRemoval() {
        guard activeTask == nil, state == .confirmation else { return }
        state = .removing
        activeTask = Task { @MainActor [self] in
            let problems = await run()
            activeTask = nil
            state = .finished(problems: problems)
        }
    }

    func showApplicationInFinder() {
        guard case .finished = state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func quitAfterRemoval() {
        guard case .finished = state else { return }
        surroundings.quit()
    }

    // MARK: - The five steps

    private func run() async -> [UninstallStep] {
        var problems: [UninstallStep] = []

        // 1. Stop polling. Cancel the tasks; do not wait for a proof.
        //
        // The point is that nothing asks a provider for a number after the user said stop,
        // and that no token refresh is still in flight when the Keychain items go. Whether
        // every cancelled task acknowledged is not a question worth answering: a cancelled
        // GET that finishes late returns a usage number nobody reads.
        if await withDeadline({ await self.surroundings.stopPolling() }) == nil {
            problems.append(.pollingStopped)
        }

        // 2. Delete the app's own Keychain service, and end the grants those credentials held.
        //    The point of no return.
        //
        // Reading comes before deleting, because after the delete there is no refresh token left
        // to revoke with. Deleting comes before any network wait, because nothing a provider does
        // -- or fails to do -- may leave a credential on this Mac after the user asked for it to
        // go. This call returns as soon as the local half is done; the revokes it started are
        // still running, and they are joined once at the very end.
        //
        // Deadlined, like every other step. Behind this one call are a Keychain enumerate, a read
        // per credential and a whole-service delete, each of them a synchronous XPC round trip to
        // `securityd` that answers when `securityd` decides -- and the vault is an actor, so a
        // refresh already inside it is in front of us with no bound of its own.
        let credentials = self.credentials
        let removal = await withDeadline { await credentials.endEveryGrant() }
        if removal?.credentialsDeleted != true {
            // Two different facts reported as one, and deliberately so: either the delete refused,
            // or it had not finished when we stopped waiting for it. The app cannot tell the user
            // their sign-ins are gone in either case. This is the safe side of that pair -- a
            // removal that in fact completed a moment later is reported as unfinished, which
            // costs the user a second look, where the reverse would cost them a credential they
            // were told was deleted.
            problems.append(.credentialsDeleted)
        }

        // 3. Remove the app's files and the preferences domain.
        //
        // The status item goes first, on the main actor where it lives: its saved position is in
        // the domain about to be removed, and AppKit rewrites it when the item is torn down with
        // an autosave name still attached.
        //
        // Then the files, off the main actor and under a deadline. This walks Application Support
        // and the Sparkle cache, and a Sparkle cache holds a downloaded and extracted app bundle,
        // so the recursion is over real work on real storage. Run on the main actor it would
        // freeze the app outright -- the removal sheet could not redraw, and no deadline could
        // resume, because a deadline's resumption is itself a main-actor hop.
        surroundings.removeStatusItem()
        let identity = self.identity
        let home = self.home
        let removedFiles = await withDeadline {
            Self.removeLocalFiles(identity: identity, home: home)
        }
        if removedFiles != true {
            problems.append(.localFilesRemoved)
        }

        // 4. Unregister the login item.
        //
        // The async overload, so this does not block the main actor while launchd answers, and
        // deadlined like every other step: a quit is refused while this runs, and an await with
        // no deadline could refuse it for ever.
        //
        // A throw is only a problem if the registration is still there afterwards -- unregistering
        // something already gone reports an error and has nothing left to do. `SMAppService` is
        // behind `LoginItemRegistration` so that both of those answers can be asked for; the
        // concrete type only ever gives the one this Mac happens to hold.
        let unregister = Task { @MainActor in
            do {
                try await loginItem.unregister()
                return true
            } catch {
                return !loginItem.isStillRegistered
            }
        }
        if await withDeadline({ await unregister.value }) != true {
            problems.append(.openAtLoginUnregistered)
        }

        // The one network wait in the whole removal, and it is last on purpose: every promise
        // this button makes about the user's Mac is already kept before it starts, so a provider
        // that will not answer costs a bounded pause and nothing else. The work keeps running
        // after the deadline -- the user's own reading of the finished screen is more time again
        // -- and it dies with the process, which is the right end for it.
        //
        // Nothing is reported from this. There is no honest thing to report: RFC 7009 has the
        // server answer 200 both for a token it revoked and for one it never issued, so a
        // "success" here would be a claim the app cannot make. Each call's outcome goes to the
        // diagnostic log. What a revoke that never lands leaves behind is a dead row on a
        // settings page the user can clear themselves.
        //
        // Nothing to join when step 2 outran its deadline: the revokes are started by the call
        // that did not return, and they run on the vault's own task for as long as the process
        // lives, which is the right end for them.
        if let removal {
            _ = await withDeadline { await removal.awaitRevocations() }
        }

        // 5. is the finished view: Finder, one sentence, quit.
        return problems
    }

    /// Removes every place this app owns, and its preferences.
    ///
    /// The places come from the identity, so a test pins the list. Each is attempted whatever the
    /// ones before it did, because a folder that refuses to go is no reason to leave the next one
    /// behind. A place that was never created is not a failure.
    ///
    /// `nonisolated` and static because this runs off the main actor, and it takes what it needs
    /// by value for the same reason. `FileManager` and `UserDefaults` are both non-`Sendable`, so
    /// neither can be carried across; the manager is made here, on the thread that uses it, and
    /// the preferences domain is addressed by name — `removePersistentDomain(forName:)` empties
    /// the named domain whichever `UserDefaults` is asked, so the receiver was never the seam.
    /// `identity` is.
    private nonisolated static func removeLocalFiles(identity: AppIdentity, home: URL) -> Bool {
        // The persistent domain first, then the file behind it. `cfprefsd` owns that file and
        // rewrites it from its own cache, so removing the domain is what empties it.
        UserDefaults.standard.removePersistentDomain(forName: identity.preferencesDomain)

        let fileManager = FileManager()
        var everythingWent = true
        for place in identity.ownedPlaces(home: home) where fileManager.fileExists(atPath: place.path) {
            do {
                try fileManager.removeItem(at: place)
            } catch {
                everythingWent = false
            }
        }
        return everythingWent
    }

    /// One step's wait, capped, with the work left running when the cap wins.
    ///
    /// Generic in the answer because two of the five steps have one: the credential removal hands
    /// back the revokes it started, and the file removal reports whether every path went. `nil`
    /// means only that this call stopped waiting.
    private func withDeadline<Value: Sendable>(
        _ work: @escaping @Sendable () async -> Value
    ) async -> Value? {
        await awaitWithinTerminationDeadline(TERMINATION_DRAIN_TIMEOUT, work)
    }
}
