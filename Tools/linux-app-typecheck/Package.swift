// swift-tools-version: 6.0
// Linux-only type-check harness for Forma's iOS BLE/platform files. The stub modules mirror the subset
// of Apple APIs those files use (as understood by the author) — this catches Swift-level errors, not SDK drift.
import PackageDescription
let package = Package(
    name: "ShimCheck",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../FormaKit")],
    targets: [
        .target(name: "CoreBluetooth"),
        .target(name: "UIKit"),
        .target(name: "AccessorySetupKit", dependencies: ["CoreBluetooth", "UIKit"]),
        .target(name: "LocalAuthentication"),
        .target(name: "UniformTypeIdentifiers"),
        .target(name: "Accessibility"),
        .target(name: "SwiftUI", dependencies: ["UIKit", "UniformTypeIdentifiers"]),
        .target(name: "Charts", dependencies: ["SwiftUI", "Accessibility"]),
        .target(name: "AppCheck", dependencies: ["CoreBluetooth", "UIKit", "AccessorySetupKit", "LocalAuthentication", "SwiftUI", "Charts", "Accessibility", "UniformTypeIdentifiers",
            .product(name: "FormaKit", package: "FormaKit")],
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-strict-concurrency=complete"])]),
    ],
    swiftLanguageModes: [.v5]
)
