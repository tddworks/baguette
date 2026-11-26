import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// Orchestration coverage for `SimctlPhotoLibrary` — argv assembly +
/// the `Subprocess` exit handshake. The irreducible `xcrun` spawn lives
/// in `HostSubprocess` (integration-only), so every branch is driven
/// through `MockSubprocess`.
@Suite("SimctlPhotoLibrary")
struct SimctlPhotoLibraryTests {

    final class Captures: @unchecked Sendable {
        var executable: URL?
        var arguments: [String]?
        var ran = false
    }

    private func makeLibrary(exitCode: Int32 = 0, deviceSetPath: String? = nil) -> (SimctlPhotoLibrary, Captures) {
        let sub = MockSubprocess()
        let captures = Captures()
        given(sub).run(
            executable: .any, arguments: .any, onBytes: .any, onExit: .any
        ).willProduce { exe, args, _, onExit in
            captures.ran = true
            captures.executable = exe
            captures.arguments = args
            onExit(exitCode)
        }
        given(sub).terminate().willReturn()
        return (SimctlPhotoLibrary(udid: "U", deviceSetPath: deviceSetPath, subprocess: sub), captures)
    }

    @Test func `should add media to the photo library via xcrun simctl addmedia with its path`() async throws {
        let (library, captures) = makeLibrary()
        try await library.add(MediaItem(path: URL(fileURLWithPath: "/tmp/clip.mov")))

        #expect(captures.executable == URL(fileURLWithPath: "/usr/bin/xcrun"))
        #expect(captures.arguments == ["simctl", "addmedia", "U", "/tmp/clip.mov"])
    }

    @Test func `should add media inside the device's custom device set when it lives in one`() async throws {
        let (library, captures) = makeLibrary(deviceSetPath: "/custom set")
        try await library.add(MediaItem(path: URL(fileURLWithPath: "/tmp/clip.mov")))

        #expect(captures.arguments == ["simctl", "--set", "/custom set", "addmedia", "U", "/tmp/clip.mov"])
    }

    @Test func `should report an add failure when simctl exits non-zero`() async {
        let (library, _) = makeLibrary(exitCode: 5)
        var caught: PhotoLibraryError?
        do {
            try await library.add(MediaItem(path: URL(fileURLWithPath: "/tmp/clip.mov")))
        } catch {
            caught = error as? PhotoLibraryError
        }
        #expect(caught == .addFailed(status: 5))
    }
}
