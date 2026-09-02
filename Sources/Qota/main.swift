import Foundation
import QotaFolioModel

// `qota` — QotaFolio's terminal command.
//
// Reads the files the app writes into its App Group container, by path, from outside the
// sandbox, and prints every account's current usage. No daemon, no socket, no network, never a
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

    Prints every account's current usage as QotaFolio last saw it: each window the provider
    reports, the percentage used, when it resets, and the app's own note for the window.
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
    switch SurfaceReading.read(container: container, identity: identity, now: now) {
    case .noApp:
        fail("qota: QotaFolio has not run yet, or has no accounts. Open QotaFolio and add one.", .noApp)
    case .unreadable:
        fail("qota: QotaFolio's files at \(container.directoryURL.path) cannot be read by this build.", .unreadable)
    case .reading(let value):
        reading = value
    }

    var recommendation: RecommendationDocument?
    if case .loaded(let data) = container.readBytes(.recommendation) {
        recommendation = RecommendationCodec.decode(data)
    }

    if wantsJSON {
        print(StatusReport.json(StatusReport.document(reading: reading, recommendation: recommendation)))
    } else if reading.accounts.isEmpty {
        print("No accounts yet. Open QotaFolio to add one.")
    } else {
        print(StatusReport.text(reading: reading, recommendation: recommendation, now: now))
    }
    exit(QotaExit.ok.rawValue)
}

run(arguments: CommandLine.arguments)
