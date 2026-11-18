import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// Quitting and launching an app — what a preferences edit wraps itself
/// in when asked to relaunch, so the app starts from the edited file.
@Suite("SimctlApps lifecycle")
struct SimctlAppsLifecycleTests {

    final class Captures: @unchecked Sendable {
        var executable: URL?
        var arguments: [String]?
    }

    private func makeApps(
        exitCode: Int32 = 0, libraries: InjectedDylibs = InjectedDylibs(paths: []), deviceSetPath: String? = nil
    ) -> (SimctlApps, Captures) {
        let sub = MockSubprocess()
        let captures = Captures()
        given(sub).run(
            executable: .any, arguments: .any, onBytes: .any, onExit: .any
        ).willProduce { executable, args, _, onExit in
            captures.executable = executable
            captures.arguments = args
            onExit(exitCode)
        }
        return (
            SimctlApps(udid: "U", deviceSetPath: deviceSetPath, subprocess: sub, libraries: { libraries }), captures
        )
    }

    @Test func `should quit a running app through simctl terminate`() async throws {
        let (apps, captures) = makeApps()
        try await apps.terminate(bundleID: "com.example.app")
        #expect(captures.arguments == ["simctl", "terminate", "U", "com.example.app"])
    }

    @Test func `should treat quitting an app that isn't running as done`() async throws {
        // simctl exits 3 ("found nothing to terminate") — measured on Xcode 27.
        let (apps, _) = makeApps(exitCode: 3)
        try await apps.terminate(bundleID: "com.example.app")
    }

    @Test func `should report a quit that failed for any other reason`() async {
        let (apps, _) = makeApps(exitCode: 149)
        await #expect(throws: AppsError.terminateFailed(status: 149)) {
            try await apps.terminate(bundleID: "com.example.app")
        }
    }

    @Test func `should launch an app through simctl launch`() async throws {
        let (apps, captures) = makeApps()
        try await apps.launch(bundleID: "com.example.app")
        #expect(captures.arguments == ["simctl", "launch", "U", "com.example.app"])
    }

    @Test func `should launch an app able to answer its preference lookups while keeping the libraries already armed`() async throws {
        // simctl hands a launched app SIMCTL_CHILD_* in place of the
        // device-wide DYLD_INSERT_LIBRARIES (measured, Xcode 27), so the
        // launch must carry the armed camera / motion / network too.
        let (apps, captures) = makeApps(libraries: InjectedDylibs(paths: [
            "/s/builds/a/VirtualMotion.dylib", "/s/builds/a/DefaultsLookups.dylib",
        ]))
        try await apps.launch(bundleID: "com.example.app")
        #expect(captures.executable?.path == "/usr/bin/env")
        #expect(captures.arguments == [
            "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=/s/builds/a/VirtualMotion.dylib:/s/builds/a/DefaultsLookups.dylib",
            "/usr/bin/xcrun", "simctl", "launch", "U", "com.example.app",
        ])
    }

    @Test func `should quit and launch an app inside the device's custom device set when it lives in one`() async throws {
        let (apps, captures) = makeApps(deviceSetPath: "/custom set")
        try await apps.terminate(bundleID: "com.example.app")
        #expect(captures.arguments == ["simctl", "--set", "/custom set", "terminate", "U", "com.example.app"])
        try await apps.launch(bundleID: "com.example.app")
        #expect(captures.arguments == ["simctl", "--set", "/custom set", "launch", "U", "com.example.app"])
    }

    @Test func `should launch an app with its libraries inside the device's custom device set when it lives in one`() async throws {
        let (apps, captures) = makeApps(
            libraries: InjectedDylibs(paths: ["/s/builds/a/DefaultsLookups.dylib"]), deviceSetPath: "/custom set")
        try await apps.launch(bundleID: "com.example.app")
        #expect(captures.arguments == [
            "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=/s/builds/a/DefaultsLookups.dylib",
            "/usr/bin/xcrun", "simctl", "--set", "/custom set", "launch", "U", "com.example.app",
        ])
    }

    @Test func `should report a launch that failed`() async {
        let (apps, _) = makeApps(exitCode: 4)
        await #expect(throws: AppsError.launchFailed(status: 4)) {
            try await apps.launch(bundleID: "com.example.app")
        }
    }
}
