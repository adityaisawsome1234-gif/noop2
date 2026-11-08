// swift-tools-version: 6.0
//
// FormaKit: the platform-independent core of Forma.
// Everything here compiles and is unit-tested on Linux and Apple platforms.
// The iOS app target (../App) adds SwiftUI + Core Bluetooth on top.

import PackageDescription

let package = Package(
    name: "FormaKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(
            name: "FormaKit",
            targets: ["FormaCore", "FormaProtocol", "FormaSync", "FormaStore", "FormaAnalytics", "FormaFeatures"]
        ),
        .executable(name: "forma-replay", targets: ["FormaReplayCLI"]),
    ],
    targets: [
        // Shared value types: time, measurements, provenance, quality flags, metric results.
        .target(name: "FormaCore"),

        // BLE payload parsing: bounds-checked bytes, CRCs, framing/reassembly, device adapters,
        // standard Heart Rate Service parser, and the command allowlist.
        .target(name: "FormaProtocol", dependencies: ["FormaCore"]),

        // Transport-agnostic sync engine: identical pipeline for live BLE and replayed captures.
        .target(name: "FormaSync", dependencies: ["FormaCore", "FormaProtocol"]),

        // System SQLite on Linux. On Apple platforms the SDK's SQLite3 module is used instead.
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", providers: [.apt(["libsqlite3-dev"])]),

        // Local persistence: SQLite, versioned migrations, export/import/backup/delete.
        .target(
            name: "FormaStore",
            dependencies: [
                "FormaCore",
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ]
        ),

        // Derived metrics with explicit specs, quality gates, coverage and confidence.
        .target(name: "FormaAnalytics", dependencies: ["FormaCore"]),

        // Screen-state logic used by the SwiftUI views (kept here so it is testable off-device).
        .target(
            name: "FormaFeatures",
            dependencies: ["FormaCore", "FormaProtocol", "FormaSync", "FormaStore", "FormaAnalytics"]
        ),

        // Desktop tool: decode an exported capture file through the same pipeline as the app.
        .executableTarget(
            name: "FormaReplayCLI",
            dependencies: ["FormaCore", "FormaProtocol", "FormaSync", "FormaStore"]
        ),

        .testTarget(name: "FormaProtocolTests", dependencies: ["FormaProtocol"], resources: [.copy("Fixtures")]),
        .testTarget(name: "FormaSyncTests", dependencies: ["FormaSync", "FormaStore", "FormaProtocol"]),
        .testTarget(name: "FormaStoreTests", dependencies: ["FormaStore"]),
        .testTarget(name: "FormaAnalyticsTests", dependencies: ["FormaAnalytics"]),
        .testTarget(name: "FormaFeaturesTests", dependencies: ["FormaFeatures", "FormaStore", "FormaAnalytics"]),
    ],
    swiftLanguageModes: [.v6]
)
