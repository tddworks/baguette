import ProjectDescription

// The phone-side of baguette's device twin — see
// ../../docs/features/device-twin.md. Three targets:
//
//   DeviceTwinCompanion  the app: pairing settings + broadcast picker
//   DeviceTwinBroadcast  ReplayKit upload extension: screen → H.264 →
//                        baguette's twin envelope over WebSocket
//   TwinWire             shared framing + transport, static so the
//                        extension pays no dylib cost against its
//                        ~50 MB memory ceiling
//
// Signing is left to Xcode's automatic management — select your team
// once in the Signing & Capabilities tab after `tuist generate`.

let appGroup = "group.com.tddworks.baguette.twin"

let sharedEntitlements: Entitlements = .dictionary([
    "com.apple.security.application-groups": .array([.string(appGroup)])
])

let project = Project(
    name: "DeviceTwin",
    targets: [
        .target(
            name: "DeviceTwinCompanion",
            destinations: .iOS,
            product: .app,
            bundleId: "com.tddworks.baguette.twin",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .extendingDefault(with: [
                "UILaunchScreen": .dictionary([:]),
                "CFBundleDisplayName": .string("Baguette Twin"),
                // The WebSocket to the Mac rides the local network;
                // without this key iOS silently refuses the connection.
                "NSLocalNetworkUsageDescription": .string(
                    "Streams this device's screen and motion to baguette on your Mac."
                ),
            ]),
            sources: ["App/Sources/**"],
            entitlements: sharedEntitlements,
            dependencies: [
                .target(name: "DeviceTwinBroadcast"),
                .target(name: "TwinWire"),
            ]
        ),
        .target(
            name: "DeviceTwinBroadcast",
            destinations: .iOS,
            product: .appExtension,
            bundleId: "com.tddworks.baguette.twin.broadcast",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": .string("Baguette Twin"),
                "NSLocalNetworkUsageDescription": .string(
                    "Streams this device's screen to baguette on your Mac."
                ),
                "NSExtension": .dictionary([
                    "NSExtensionPointIdentifier": .string("com.apple.broadcast-services-upload"),
                    "NSExtensionPrincipalClass": .string("$(PRODUCT_MODULE_NAME).SampleHandler"),
                    "RPBroadcastProcessMode": .string("RPBroadcastProcessModeSampleBuffer"),
                ]),
            ]),
            sources: ["Broadcast/Sources/**"],
            entitlements: sharedEntitlements,
            dependencies: [
                .target(name: "TwinWire")
            ]
        ),
        .target(
            name: "TwinWire",
            destinations: .iOS,
            product: .staticFramework,
            bundleId: "com.tddworks.baguette.twin.wire",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .default,
            sources: ["Wire/Sources/**"]
        ),
    ]
)
