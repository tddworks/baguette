// swift-tools-version: 6.1

import PackageDescription

let privateFrameworkFlags: [String] = [
    "-F/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks",
    "-F/Library/Developer/PrivateFrameworks",
]

let rpathFlags: [String] = [
    "-Xlinker", "-rpath", "-Xlinker", "/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks",
    "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/PrivateFrameworks",
]

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
                .unsafeFlags(privateFrameworkFlags),
                // MOCKING is debug-only; release strips mock code entirely.
                .define("MOCKING", .when(configuration: .debug)),
            ],
            linkerSettings: [
                .unsafeFlags(privateFrameworkFlags + rpathFlags),
                .linkedFramework("CoreSimulator"),
                .linkedFramework("SimulatorKit"),
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
