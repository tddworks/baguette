// swift-tools-version: 6.1

import PackageDescription

// A package that uses Baguette as a library, the way a host such as SimKit
// does: it depends on the `BaguetteKit` product and nothing else. CI builds
// it so a change that breaks the library breaks the build.
let package = Package(
    name: "ListSimulators",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(name: "baguette", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "ListSimulators",
            dependencies: [
                .product(name: "BaguetteKit", package: "baguette"),
            ]
        ),
    ]
)
