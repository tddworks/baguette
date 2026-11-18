// swift-tools-version: 6.1

import Foundation
import PackageDescription

// CoreDevice (Xcode's private device stack) is weak-linked when this Mac has
// it, so Swift binds its symbols directly with @_silgen_name. Both install
// names are absolute and outside Xcode.app, unlike SimulatorKit below, and a
// weak link lets a Mac without them still launch: `CoreDeviceFramework`
// checks before any call. A machine that builds without CoreDevice compiles
// the phone touch path out (no COREDEVICE define).
let coreDeviceHome = "/Library/Developer/PrivateFrameworks"
let universalHIDHome = coreDeviceHome + "/CoreDevice.framework/Versions/A/Frameworks"
let hasCoreDevice = FileManager.default.fileExists(atPath: coreDeviceHome + "/CoreDevice.framework/CoreDevice")
    && FileManager.default.fileExists(atPath: universalHIDHome + "/UniversalHID.framework/UniversalHID")
let coreDeviceLinking: [LinkerSetting] = hasCoreDevice ? [.unsafeFlags([
    "-F", coreDeviceHome, "-Xlinker", "-weak_framework", "-Xlinker", "CoreDevice",
    "-F", universalHIDHome, "-Xlinker", "-weak_framework", "-Xlinker", "UniversalHID",
])] : []
let coreDeviceDefine: [SwiftSetting] = hasCoreDevice ? [.define("COREDEVICE")] : []

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
        // The one CoreDevice call Swift can't spell: a typed-throws send
        // whose error slot sits before the type metadata. Everything else
        // is Swift (Devices/iPhone/Internal/Kit).
        .target(
            name: "CoreDeviceABI",
            path: "Sources/CoreDeviceABI"
        ),
        // What a device is: its id, kind and state, how it looks (Chrome)
        // and what it can do (Abilities) — the roles and their values. The
        // innermost context: it depends on nothing of baguette's.
        .target(
            name: "BaguetteDevice",
            dependencies: [
                .product(name: "Mockable", package: "Mockable"),
            ],
            path: "Sources/Device",
            swiftSettings: [
                .define("MOCKING", .when(configuration: .debug)),
            ]
        ),
        .executableTarget(
            name: "Baguette",
            dependencies: [
                "BaguetteDevice",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Mockable", package: "Mockable"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                "CoreDeviceABI",
            ],
            // The two ways in (Commands, Server), the device families
            // (Devices) and the plugins, around the one `@main` in
            // Sources/Baguette, which also keeps the resources.
            path: "Sources",
            // Their own targets; listed so this one doesn't warn about them.
            exclude: ["Device", "CoreDeviceABI"],
            sources: ["Baguette/RootCommand.swift", "Commands", "Server", "Devices", "Plugins"],
            resources: [
                // Static HTML/CSS/JS for `baguette serve`. Each file is
                // self-contained — open in a browser via file:// for a
                // design preview without booting the server.
                .copy("Baguette/Resources/Web"),
                // Data-driven 3D device definitions. Large USDZ assets are
                // downloaded from their declared source and SHA-256 verified.
                .copy("Baguette/Resources/Models3D"),
                // Plugins baguette ships (the reference accessibility
                // audit). Resolved at runtime by `PluginRoot`, the same
                // three-step lookup `WebRoot` uses for the web assets.
                .copy("Baguette/Resources/Plugins"),
                // iOS-Simulator dylib (vendored under `VirtualCamera/`,
                // built by `VirtualCamera/build.sh` and staged here by
                // the top-level `build.sh`). `InjectedDylibInstaller`
                // resolves the bundle path at runtime.
                .copy("Baguette/Resources/VirtualCamera"),
                // The motion counterpart — answers CMMotionActivityManager,
                // CMPedometer and CMMotionManager from the intent baguette
                // publishes. Same build-and-stage path, same installer.
                .copy("Baguette/Resources/VirtualMotion"),
                // The network counterpart — conditions an app's own
                // URLSession traffic from the condition baguette publishes.
                // Same build-and-stage path, same installer.
                .copy("Baguette/Resources/VirtualNetwork"),
                // Lets an app baguette launches say which preferences it
                // looks up. Same build-and-stage path, same installer, but
                // handed to one launch rather than armed device-wide.
                .copy("Baguette/Resources/DefaultsLookups"),
                // HingeControl — not a dylib but an executable spawned in
                // the guest (`simctl spawn`) to drive iPhone Duo's hinge.
                // Same build-and-stage path, same installer.
                .copy("Baguette/Resources/HingeControl"),
            ],
            swiftSettings: [
                // MOCKING is debug-only; release strips mock code entirely.
                .define("MOCKING", .when(configuration: .debug)),
            ] + coreDeviceDefine,
            linkerSettings: coreDeviceLinking + [
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                    .linkedFramework("SceneKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("VideoToolbox"),
            ]
        ),
        .testTarget(
            name: "BaguetteTests",
            dependencies: [
                "Baguette",
                "BaguetteDevice",
                .product(name: "Mockable", package: "Mockable"),
            ],
            path: "Tests/BaguetteTests",
            resources: [
                // Pre-encoded H.264 clips for `AVVideoDecoderTests`. The
                // decoder needs a real asset, but synthesising one at test
                // time means encoding H.264 on whatever runs the suite —
                // and a CI runner with no usable VideoToolbox encoder
                // stalls the write instead of failing it.
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .define("MOCKING"),
            ]
        ),
    ]
)
