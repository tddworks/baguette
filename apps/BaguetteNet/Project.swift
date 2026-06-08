import ProjectDescription

// BaguetteNet — macOS host app + NetworkExtension content-filter system
// extension that throttles a single simulator's traffic (bandwidth /
// latency / packet loss) while leaving the Mac's connection untouched.
//
// Two targets:
//   • BaguetteNet           — the host .app. Activates + embeds the
//                             system extension and writes the chosen
//                             NetworkProfile into the shared app group.
//   • BaguetteNetExtension  — the .systemextension. An NEFilterDataProvider
//                             that reads the profile back and enforces it.
//
// Building/running needs a real Apple Developer team (the
// content-filter-provider entitlement is not ad-hoc-signable) — set
// DEVELOPMENT_TEAM below or via `tuist generate`. `tuist generate` itself
// works without a team.

let bundlePrefix = "com.tddworks.baguette.net"
let appGroup = "group.com.tddworks.baguette.net"

// Non-signing settings stay inline; signing (team + per-config identity) lives
// in XCConfig/{shared,debug,release}.xcconfig, mirroring the working AppNexus
// setup (Products/AppNexus/Resources/XCConfig). Team Y5856NSDZU owns the App
// IDs + capabilities; the reusable "Apple Development" cert signs against it.
let commonSettings: SettingsDictionary = [
    "SWIFT_VERSION": "6.0",
    "MARKETING_VERSION": "0.1.0",
    "CURRENT_PROJECT_VERSION": "1",
]

let project = Project(
    name: "BaguetteNet",
    organizationName: "tddworks",
    settings: .settings(
        base: commonSettings,
        configurations: [
            .debug(name: .debug, xcconfig: "XCConfig/debug.xcconfig"),
            .release(name: .release, xcconfig: "XCConfig/release.xcconfig"),
        ],
        // Keep Tuist's recommended defaults, but drop its CODE_SIGN_IDENTITY
        // (which it sets to "-" / Sign to Run Locally for macOS targets). That
        // default would override the xcconfig and force ad-hoc signing on the
        // entitled targets; excluding it lets the xcconfig identity win.
        defaultSettings: .recommended(excluding: ["CODE_SIGN_IDENTITY"])
    ),
    targets: [
        // ── Shared pure domain (the testable core) ─────────────────
        // A framework so the app, the extension, and the tests all link
        // one copy. No entitlement needed, so tests build without signing.
        .target(
            name: "BaguetteNetKit",
            destinations: .macOS,
            product: .framework,
            bundleId: "\(bundlePrefix).kit",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["Shared/**"]
        ),

        // ── Host app ───────────────────────────────────────────────
        .target(
            name: "BaguetteNet",
            destinations: .macOS,
            product: .app,
            bundleId: bundlePrefix,
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Baguette Net",
                "LSUIElement": false,
                "NSSystemExtensionUsageDescription":
                    "Baguette Net uses a system extension to throttle a simulator's network without affecting your Mac.",
            ]),
            sources: ["App/Sources/**"],
            resources: ["App/Resources/**"],
            entitlements: "App/BaguetteNet.entitlements",
            dependencies: [
                .target(name: "BaguetteNetKit"),
                // Embeds the system extension into
                // Contents/Library/SystemExtensions of the app.
                .target(name: "BaguetteNetExtension"),
            ],
            settings: .settings(configurations: [
                .debug(name: .debug),
                .release(
                    name: .release,
                    settings: [
                        "CODE_SIGN_ENTITLEMENTS": "App/BaguetteNet-release.entitlements",
                        "CODE_SIGN_IDENTITY": "Developer ID Application",
                        "CODE_SIGN_STYLE": "Manual",
                        "PROVISIONING_PROFILE_SPECIFIER": "BaguetteNet Developer ID",
                    ]
                ),
            ])
        ),

        // ── Content-filter system extension ────────────────────────
        .target(
            name: "BaguetteNetExtension",
            destinations: .macOS,
            product: .systemExtension,
            bundleId: "\(bundlePrefix).extension",
            deploymentTargets: .macOS("14.0"),
            // .extendingDefault so Tuist auto-generates the standard CFBundle*
            // keys (CFBundleIdentifier, CFBundleExecutable, version, …). A raw
            // Info.plist file is passed through verbatim and would ship without
            // CFBundleIdentifier, which breaks archive export ("Bundle
            // identifier is missing").
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "BaguetteNetExtension",
                "CFBundlePackageType": "SYSX",
                "NSSystemExtensionUsageDescription":
                    "Baguette Net uses a network extension to throttle Simulator app traffic.",
                "NetworkExtension": [
                    // App-group mach service the host app talks to the provider
                    // over; must be team-id-prefixed.
                    "NEMachServiceName": "$(TeamIdentifierPrefix)group.com.tddworks.baguette.net",
                    "NEProviderClasses": [
                        "com.apple.networkextension.filter-data": "$(PRODUCT_MODULE_NAME).FilterDataProvider",
                    ],
                ],
            ]),
            sources: ["Extension/Sources/**"],
            entitlements: "Extension/BaguetteNetExtension.entitlements",
            dependencies: [
                .target(name: "BaguetteNetKit"),
            ],
            settings: .settings(
                base: [
                    // SystemExtensions discovers a NetworkExtension by requiring
                    // its bundle filename to equal its bundle identifier.
                    "PRODUCT_NAME": "\(bundlePrefix).extension",
                ],
                configurations: [
                    .debug(name: .debug),
                    .release(
                        name: .release,
                        settings: [
                            "CODE_SIGN_ENTITLEMENTS": "Extension/BaguetteNetExtension-release.entitlements",
                            "CODE_SIGN_IDENTITY": "Developer ID Application",
                            "CODE_SIGN_STYLE": "Manual",
                            "PROVISIONING_PROFILE_SPECIFIER": "BaguetteNetExtension Developer ID",
                        ]
                    ),
                ]
            )
        ),

        // ── Unit tests for the pure throttle math ──────────────────
        .target(
            name: "BaguetteNetKitTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "\(bundlePrefix).tests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["Tests/**"],
            dependencies: [
                .target(name: "BaguetteNetKit"),
            ]
        ),
    ],
    additionalFiles: [
        "App/BaguetteNet-release.entitlements",
        "Extension/BaguetteNetExtension-release.entitlements",
    ]
)
