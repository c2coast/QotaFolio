import Foundation
import Kit
import QotaFolioModel

// `qota` — QotaFolio's terminal command.
//
// Reads the files the app writes into its App Group container, by path, and prints the current
// usage of every account the person has not hidden. No daemon, no socket, no network, never a
// token. It ships inside the app at Contents/MacOS/qota and takes its identity from that app,
// so a development build's `qota` reads the development build's files and nobody else's.

nonisolated enum QotaExit: Int32 {
    case ok = 0
    case usage = 64
    case noApp = 2
    case unreadable = 3
}

nonisolated func usage() -> String {
    """
    usage: qota status [--json]
           qota --version
           qota --help

    Prints every account's current usage as QotaFolio last saw it, in the words of its card: each
    limit the provider reports, the percentage used, when it resets, and for the week and the
    model's week whether it lasts.
    --json prints the same as one document (schema \(StatusReport.schemaVersion)).
    """
}

/// The app bundle this command ships inside: three directories up from the executable.
nonisolated func hostIdentity() -> AppIdentity? {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let appURL = executable
        .deletingLastPathComponent()   // MacOS
        .deletingLastPathComponent()   // Contents
        .deletingLastPathComponent()   // QotaFolio.app
    guard appURL.pathExtension == "app",
          let host = Bundle(url: appURL),
          let identifier = host.bundleIdentifier,
          !identifier.isEmpty
    else { return nil }
    return AppIdentity(bundle: host)
}

nonisolated func fail(_ message: String, _ code: QotaExit) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code.rawValue)
}

nonisolated func run(arguments: [String]) -> Never {
    var wantsJSON = false
    var command = "status"
    for argument in arguments.dropFirst() {
        switch argument {
        case "--json": wantsJSON = true
        case "--help", "-h", "help":
            print(usage())
            exit(QotaExit.ok.rawValue)
        case "--version", "version":
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            print("qota \(version ?? "development")")
            exit(QotaExit.ok.rawValue)
        case "status": command = "status"
        default:
            fail("qota: unknown argument \(argument)\n" + usage(), .usage)
        }
    }
    guard command == "status" else { fail(usage(), .usage) }

    guard let identity = hostIdentity() else {
        fail(
            "qota: run it from inside the app it ships in — for example\n" +
            "  /Applications/QotaFolio.app/Contents/MacOS/qota status",
            .usage
        )
    }

    let now = Date()
    guard let container = try? SharedContainer.resolve(identity: identity, create: false) else {
        fail("qota: QotaFolio has not run yet, or has no accounts.", .noApp)
    }

    let reading: SurfaceReading
    switch SurfaceReading.read(container: container, now: now) {
    case .noApp:
        fail("qota: QotaFolio has not run yet, or has no accounts. Open QotaFolio and add one.", .noApp)
    case .unreadable:
        fail("qota: QotaFolio's files at \(container.directoryURL.path) cannot be read by this build.", .unreadable)
    case .reading(let value):
        // The panel leaves out the accounts the person hid in Settings, and so does this command. The app keeps
        // the list in its preferences domain, which this process reads by the domain's name. This process's main
        // bundle is the app, and Foundation ignores a suite named after the main bundle, so it reads the domain whole.
        let domain = UserDefaults.standard.persistentDomain(forName: identity.preferencesDomain)
        let hidden = HiddenAccounts.ids(stored: domain?[HiddenAccounts.key] as? [String])
        reading = value.hiding(hidden)
    }

    // The readings the app's card reads, from the same two books through the same reader. A book
    // that is absent is no history; one this build cannot read is said so.
    let readings: [[Reading]]
    switch (container.readBytes(.traces), container.readBytes(.snapshots)) {
    case (.unreadable, _), (_, .unreadable):
        fail("qota: QotaFolio's history at \(container.directoryURL.path) cannot be read by this build.", .unreadable)
    case (let history, let snapshots):
        do {
            readings = try LegacyHistory.readings(
                history: history.data,
                snapshots: snapshots.data
            )
        } catch {
            fail("qota: QotaFolio's history at \(container.directoryURL.path) cannot be read by this build: \(error)", .unreadable)
        }
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let words = TimeWords(calendar: calendar, twelveHour: Locale.current.clockIsTwelveHour, now: now)
    let accounts = StatusReport.said(reading, readings, words: words)

    if wantsJSON {
        print(StatusReport.json(StatusReport.document(accounts, newest: readings, observedAt: reading.observedAt)))
    } else if reading.accounts.isEmpty {
        print("No accounts yet. Open QotaFolio to add one.")
    } else {
        print(StatusReport.text(accounts, observedAt: reading.observedAt, words: words))
    }
    exit(QotaExit.ok.rawValue)
}

private extension SharedFileRead {
    nonisolated var data: Data? { if case .loaded(let data) = self { data } else { nil } }
}

run(arguments: CommandLine.arguments)
