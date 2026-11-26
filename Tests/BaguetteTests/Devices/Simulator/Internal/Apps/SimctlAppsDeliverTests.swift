import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// Delivering a remote notification through `simctl push` — the payload
/// travels as a file (simctl reads a path), and a refusal carries
/// simctl's own words so "app not installed" isn't reduced to an exit code.
@Suite("SimctlApps deliver")
struct SimctlAppsDeliverTests {

    final class Captures: @unchecked Sendable {
        var arguments: [String]?
        var payloadOnDisk: Data?
    }

    private let note = try! RemoteNotification.from(
        json: Data(#"{"aps":{"alert":"Hi"},"deep_link":"example://orders/123"}"#.utf8),
        addressedTo: "com.example.app"
    )

    private func makeApps(
        exitCode: Int32 = 0, output: String = "", deviceSetPath: String? = nil
    ) -> (SimctlApps, Captures) {
        let sub = MockSubprocess()
        let captures = Captures()
        given(sub).run(
            executable: .any, arguments: .any, onBytes: .any, onExit: .any
        ).willProduce { _, args, onBytes, onExit in
            captures.arguments = args
            captures.payloadOnDisk = args.last.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            if !output.isEmpty { onBytes(Data(output.utf8)) }
            onExit(exitCode)
        }
        return (SimctlApps(udid: "U", deviceSetPath: deviceSetPath, subprocess: sub), captures)
    }

    @Test func `should deliver a notification to its app through simctl push`() async throws {
        let (apps, captures) = makeApps()
        try await apps.deliver(note)
        #expect(Array(captures.arguments?.prefix(4) ?? []) == ["simctl", "push", "U", "com.example.app"])
    }

    @Test func `should deliver a notification inside the device's custom device set when it lives in one`() async throws {
        let (apps, captures) = makeApps(deviceSetPath: "/custom set")
        try await apps.deliver(note)
        #expect(Array(captures.arguments?.prefix(6) ?? [])
            == ["simctl", "--set", "/custom set", "push", "U", "com.example.app"])
    }

    @Test func `should hand simctl the payload exactly as written`() async throws {
        let (apps, captures) = makeApps()
        try await apps.deliver(note)
        #expect(captures.payloadOnDisk == note.payload)
    }

    @Test func `should leave no payload file behind after delivering`() async throws {
        let (apps, captures) = makeApps()
        try await apps.deliver(note)
        let path = try #require(captures.arguments?.last)
        #expect(FileManager.default.fileExists(atPath: path) == false)
    }

    @Test func `should report a refused delivery in simctl's own words`() async {
        let (apps, _) = makeApps(
            exitCode: 22,
            output: "An error was encountered processing the command (domain=SimulatorKit, code=1):\nNotification could not be delivered.\n"
        )
        await #expect(throws: AppsError.deliverFailed(
            status: 22,
            message: "An error was encountered processing the command (domain=SimulatorKit, code=1):\nNotification could not be delivered."
        )) {
            try await apps.deliver(note)
        }
    }

    @Test func `should report that the app isn't allowed notifications when the simulator says its source is not authorized`() async {
        // Measured, iOS 27: an installed app that never asked for
        // permission (and an app that isn't installed) both get this.
        let (apps, _) = makeApps(
            exitCode: 211,
            output: "An error was encountered processing the command (domain=UNErrorDomain, code=2003):\nSimulator device failed to complete the requested operation.\nUnderlying error (domain=UNErrorDomain, code=2003):\n\tRepository could not save notification. Source is not authorized.\n"
        )
        await #expect(throws: AppsError.notificationsNotAllowed(app: "com.example.app")) {
            try await apps.deliver(note)
        }
    }

    @Test func `should tell the developer how to let an app receive notifications`() {
        #expect(AppsError.notificationsNotAllowed(app: "com.example.app").description
            == "com.example.app isn't allowed to receive notifications: it must ask with "
            + "UNUserNotificationCenter.requestAuthorization and be allowed (or it isn't installed)")
    }

    @Test func `should name the exit status when simctl refuses a delivery without saying why`() {
        #expect(AppsError.deliverFailed(status: 22, message: "").description == "xcrun simctl push exited 22")
    }

    @Test func `should name the exit status alongside simctl's reason`() {
        #expect(AppsError.deliverFailed(status: 22, message: "Unable to lookup app").description
            == "xcrun simctl push exited 22: Unable to lookup app")
    }
}
