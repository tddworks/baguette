import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// Orchestration coverage for `SimctlPasteboard` — argv assembly, the
/// stdin handoff for `pbcopy`, and the `Subprocess` exit handshake.
/// The irreducible `xcrun` spawn lives in `HostSubprocess`
/// (integration-only), so every branch here is driven through
/// `MockSubprocess`.
@Suite("SimctlPasteboard")
struct SimctlPasteboardTests {

    final class Captures: @unchecked Sendable {
        var executable: URL?
        var arguments: [String]?
        var stdin: Data?
        /// Every argv handed to the stdin-carrying `run`, in order.
        var writes: [[String]] = []
    }

    /// `exitCode` answers every spawn; `devicectlExit` overrides the
    /// Core Device copy so the fallback can be driven.
    private func makePasteboard(
        exitCode: Int32 = 0, devicectlExit: Int32? = nil, stdout: Data? = nil, deviceSetPath: String? = nil
    ) -> (SimctlPasteboard, Captures) {
        let sub = MockSubprocess()
        let captures = Captures()
        given(sub).run(
            executable: .any, arguments: .any, stdin: .any, onBytes: .any, onExit: .any
        ).willProduce { exe, args, stdin, _, onExit in
            captures.executable = exe
            captures.arguments = args
            captures.stdin = stdin
            captures.writes.append(args)
            if args.first == "devicectl", let devicectlExit {
                onExit(devicectlExit)
            } else {
                onExit(exitCode)
            }
        }
        given(sub).run(
            executable: .any, arguments: .any, onBytes: .any, onExit: .any
        ).willProduce { exe, args, onBytes, onExit in
            captures.executable = exe
            captures.arguments = args
            if let stdout { onBytes(stdout) }
            onExit(exitCode)
        }
        given(sub).terminate().willReturn()
        return (SimctlPasteboard(udid: "U", deviceSetPath: deviceSetPath, subprocess: sub), captures)
    }

    @Test func `should set the pasteboard through devicectl first with the text on stdin`() async throws {
        let (pasteboard, captures) = makePasteboard()
        try await pasteboard.setText("hi")

        #expect(captures.executable == URL(fileURLWithPath: "/usr/bin/xcrun"))
        #expect(captures.writes == [["devicectl", "device", "pasteboard", "copy", "--device", "U"]])
        #expect(captures.stdin == Data("hi".utf8))
    }

    @Test func `should fall back to simctl pbcopy when devicectl refuses the copy`() async throws {
        // Xcode 26 has no `pasteboard` subcommand (usage error, 64);
        // a device Core Device does not know exits 1. Either way the
        // legacy route gets the same bytes.
        for refusal: Int32 in [64, 1] {
            let (pasteboard, captures) = makePasteboard(devicectlExit: refusal)
            try await pasteboard.setText("hi")
            #expect(captures.writes == [
                ["devicectl", "device", "pasteboard", "copy", "--device", "U"],
                ["simctl", "pbcopy", "U"],
            ])
            #expect(captures.stdin == Data("hi".utf8))
        }
    }

    @Test func `should set the pasteboard with simctl pbcopy inside the custom device set when the device lives in one`() async throws {
        // Core Device only knows the default device set, so devicectl
        // can't address a device in a custom one; pbcopy with `--set` can.
        let (pasteboard, captures) = makePasteboard(deviceSetPath: "/custom set")
        try await pasteboard.setText("hi")
        #expect(captures.writes == [["simctl", "--set", "/custom set", "pbcopy", "U"]])
        #expect(captures.stdin == Data("hi".utf8))
    }

    @Test func `should read and sync the pasteboard inside the custom device set when the device lives in one`() async throws {
        let (pasteboard, captures) = makePasteboard(deviceSetPath: "/custom set")
        _ = try await pasteboard.text()
        #expect(captures.arguments == ["simctl", "--set", "/custom set", "pbpaste", "U"])
        try await pasteboard.syncFromHost()
        #expect(captures.arguments == ["simctl", "--set", "/custom set", "pbsync", "host", "U"])
        try await pasteboard.syncToHost()
        #expect(captures.arguments == ["simctl", "--set", "/custom set", "pbsync", "U", "host"])
    }

    @Test func `should report the pbcopy status when both pasteboard routes fail`() async throws {
        let (pasteboard, _) = makePasteboard(exitCode: 3, devicectlExit: 1)
        await #expect(throws: PasteboardError.simctlFailed(status: 3)) {
            try await pasteboard.setText("hi")
        }
    }

    @Test func `should send non-ASCII pasteboard text as UTF-8 bytes`() async throws {
        let (pasteboard, captures) = makePasteboard()
        try await pasteboard.setText("héllo 🥖")
        #expect(captures.stdin == Data("héllo 🥖".utf8))
    }

    @Test func `should read the pasteboard text from simctl pbpaste`() async throws {
        let (pasteboard, captures) = makePasteboard(
            stdout: Data("clip contents".utf8)
        )
        let text = try await pasteboard.text()
        #expect(captures.arguments == ["simctl", "pbpaste", "U"])
        #expect(text == "clip contents")
    }

    @Test func `should sync the host pasteboard onto the device with simctl pbsync`() async throws {
        let (pasteboard, captures) = makePasteboard()
        try await pasteboard.syncFromHost()
        #expect(captures.arguments == ["simctl", "pbsync", "host", "U"])
        #expect(captures.stdin == nil)
    }

    @Test func `should sync the device pasteboard onto the host with simctl pbsync`() async throws {
        let (pasteboard, captures) = makePasteboard()
        try await pasteboard.syncToHost()
        #expect(captures.arguments == ["simctl", "pbsync", "U", "host"])
        #expect(captures.stdin == nil)
    }

    @Test func `should fail setting the pasteboard when simctl exits non-zero`() async {
        let (pasteboard, _) = makePasteboard(exitCode: 3)
        var caught: PasteboardError?
        do {
            try await pasteboard.setText("hi")
        } catch {
            caught = error as? PasteboardError
        }
        #expect(caught == .simctlFailed(status: 3))
    }
}
