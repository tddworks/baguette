import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// `serve` died of `-[NSConcreteFileHandle readDataOfLength:]: Bad file
/// descriptor` inside `xcode-select -p` once a long-lived hinge watch
/// sat next to short `angle()` spawns that are terminated early. This
/// drives that shape hard: one long child, many short children
/// terminated before they exit, and a bystander doing plain
/// `Process` + `Pipe` reads throughout. The bystander must never lose
/// its descriptor.
@Suite("HostSubprocess under concurrent spawns", .serialized)
struct HostSubprocessStressTests {

    private func bystanderRead() -> Bool {
        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/echo")
        task.arguments = ["ok"]
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        try? pipe.fileHandleForReading.close()
        return String(decoding: data, as: UTF8.self).contains("ok")
    }

    @Test func `should never close a bystander's pipe when short children are stopped beside a long one`() async throws {
        let long = HostSubprocess()
        try long.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "while :; do echo tick; sleep 0.01; done"],
            onBytes: { _ in }, onExit: { _ in }
        )
        defer { long.terminate() }

        for _ in 0..<40 {
            let short = HostSubprocess()
            try short.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo sample; sleep 5"],
                onBytes: { _ in }, onExit: { _ in }
            )
            try await Task.sleep(for: .milliseconds(15))
            short.terminate()
            // A readability source that closes its descriptor on
            // cancellation does so asynchronously; keep taking
            // descriptors for a while after the terminate.
            for _ in 0..<6 {
                #expect(bystanderRead(), "a bystander's pipe read failed")
            }
        }
    }
}
