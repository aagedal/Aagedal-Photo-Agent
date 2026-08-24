// swift-tools-version: 6.0

import PackageDescription

// Local fork of SwiftExif 1.9.10. Keep this package deliberately limited to the library product
// consumed by Photo Agent; fork provenance and the maintained delta are documented in README.md.
let package = Package(
    name: "SwiftExif",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "SwiftExif", targets: ["SwiftExif"]),
    ],
    targets: [
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib",
            providers: [.brew(["zlib"]), .apt(["zlib1g-dev"])]
        ),
        .target(
            name: "SwiftExif",
            dependencies: ["CZlib"],
            path: "Sources/SwiftExif",
            linkerSettings: [
                .linkedLibrary("z", .when(platforms: [.macOS, .iOS])),
            ]
        ),
    ]
)
