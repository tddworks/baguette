// swift-tools-version: 6.1

import PackageDescription

// SimulatorKit + CoreSimulator are deliberately NOT linked here. Nothing
// in Sources/ does `import SimulatorKit` / `import CoreSimulator` — the
// Swift code reaches into them via `NSClassFromString` + `dlsym` (see
// `CoreSimulators.loadFrameworks()` and `IndigoHIDInput.warmUp()`),
// after discovering the active Xcode through `xcode-select -p`.
//
// Linking them at build time would bake LC_LOAD_DYLIB entries that dyld
// must resolve before `main()` runs, which fails for users whose Xcode
// lives anywhere other than `/Applications/Xcode.app` (issue #1). The
// runtime dlopen path already handles every install location correctly.
let package = Package(
    name: "Baguette",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.1"),
        // `@Mockable` auto-generates `MockXxx` classes from `@Mockable`
        // protocols under the `MOCKING` compilation condition.
        .package(url: "https://github.com/Kolos65/Mockable", from: "0.4.0"),
        // HTTP + WebSocket server for `baguette serve`.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.22.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Baguette",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Mockable", package: "Mockable"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ],
            path: "Sources/Baguette",
            resources: [
                // Static HTML/CSS/JS for `baguette serve`. Each file is
                // self-contained — open in a browser via file:// for a
                // design preview without booting the server.
                .copy("Resources/Web"),
            ],
            swiftSettings: [
                // MOCKING is debug-only; release strips mock code entirely.
                .define("MOCKING", .when(configuration: .debug)),
            ],
            linkerSettings: [
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ImageIO"),
                .linkedFramework("VideoToolbox"),
            ]
        ),
        .testTarget(
            name: "BaguetteTests",
            dependencies: [
                "Baguette",
                .product(name: "Mockable", package: "Mockable"),
            ],
            path: "Tests/BaguetteTests",
            swiftSettings: [
                .define("MOCKING"),
            ]
        ),
    ]
)
