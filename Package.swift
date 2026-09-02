// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QotaFolioCore",
    platforms: [.macOS(.v26)],
    products: [
        // The files this app writes, and the types they decode into. Linked on its own by
        // anything that only reads them: the widget extension and the `qota` command.
        .library(name: "QotaFolioModel", targets: ["QotaFolioModel"]),
        .library(name: "QotaFolioCore", targets: ["QotaFolioCore"]),
        .library(name: "QotaFolioCoreXcode", type: .dynamic, targets: ["QotaFolioCore"]),
    ],
    targets: [
        // No `defaultIsolation`, and that is the whole reason this target exists.
        // `defaultIsolation(MainActor.self)` isolates every synthesized `Codable` conformance
        // to the main actor, and a widget extension decoding on its own queue cannot use a
        // main-actor conformance — the compiler refuses it (`isolated-conformances`). So the
        // types that cross into an extension are compiled with no default isolation at all,
        // stay `nonisolated`, and decode wherever they are read. No resources either: a
        // static library carrying a bundle is a resource-lookup problem in an extension, and
        // nothing here has a word to say to the user. Words are Core's.
        .target(
            name: "QotaFolioModel",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "QotaFolioCore",
            dependencies: ["QotaFolioModel"],
            resources: [.process("Resources")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
    ]
)
