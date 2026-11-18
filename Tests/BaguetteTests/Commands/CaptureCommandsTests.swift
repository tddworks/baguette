import CoreVideo
import Foundation
import IOSurface
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// `baguette screenshot`, `stream`, `logs` and `record` run against the
/// devices and terminal a test hands them.
@Suite("Capture commands", .serialized)
struct CaptureCommandsTests {

    private struct Refused: Error, CustomStringConvertible {
        var description: String { "refused" }
    }

    /// A screen that hands over one 4×8 frame when started — or none, or
    /// refuses to start.
    private func screen(frame: Bool = true, failing: Bool = false) throws -> MockScreen {
        let surface = try #require(IOSurface(properties: [
            .width: 4, .height: 8, .bytesPerElement: 4, .bytesPerRow: 16,
            .pixelFormat: kCVPixelFormatType_32BGRA, .allocSize: 128,
        ]))
        let screen = MockScreen()
        if failing {
            given(screen).start(onFrame: .any).willThrow(Refused())
        } else {
            given(screen).start(onFrame: .any).willProduce { onFrame in if frame { onFrame(surface) } }
        }
        given(screen).stop().willReturn(())
        return screen
    }

    private func showing(_ screen: MockScreen) -> any Devices {
        routeDevices { $0.register(.screen) { screen } }
    }

    private func temporary(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID())-\(name)")
    }

    // MARK: - screenshot

    @Test func `should write one frame of the device's screen to the file given, and its geometry`() async throws {
        let image = temporary("shot.png"), metadata = temporary("shot.json")
        defer {
            try? FileManager.default.removeItem(at: image)
            try? FileManager.default.removeItem(at: metadata)
        }

        let ran = try await run(
            try ScreenshotCommand.parse(["--udid", "U", "-o", image.path, "--metadata-output", metadata.path]),
            on: showing(try screen()))

        #expect(ran.exit == 0)
        #expect(try Data(contentsOf: image).starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let geometry = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        #expect(!geometry.isEmpty)
    }

    @Test func `should exit 1 when no CarPlay screen is attached to capture`() async throws {
        let display = MockDisplay()
        given(display).resolve().willThrow(FramebufferSelectionError.noMatchingFramebuffer(.carPlay))
        let displays = MockDisplays()
        given(displays).carPlay.willReturn(display)
        let external = MockExternalDisplays()
        given(external).enableCarPlay().willReturn()

        let ran = try await run(
            try ScreenshotCommand.parse(["--udid", "U", "--display", "carplay", "-o", temporary("x.png").path]),
            on: routeDevices {
                $0.register(.displays) { displays }
                $0.register(.externalDisplays) { external }
            })

        #expect(ran.exit == 1)
        #expect(ran.told == [FramebufferSelectionError.noMatchingFramebuffer(.carPlay).message])
    }

    @Test func `should exit 1 capturing a device with no screen`() async throws {
        let ran = try await run(try ScreenshotCommand.parse(["--udid", "U", "-o", temporary("x.png").path]),
                                on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do screen"])
    }

    // MARK: - stream

    @Test(.timeLimit(.minutes(1)))
    func `should stream the device's screen until interrupted, then let it go`() async throws {
        let screen = try screen(frame: false)

        let ran = try await run(try StreamCommand.parse(["--udid", "U"]), on: showing(screen),
                                terminal: Terminal(lines: [], interrupted: true))

        #expect(ran.exit == 0)
    }

    @Test func `should exit 1 naming a stream format it doesn't know`() async throws {
        let ran = try await run(try StreamCommand.parse(["--udid", "U", "--format", "gif"]),
                                on: showing(try screen()))

        #expect(ran.exit == 1)
        #expect(ran.told == ["Unknown format: gif"])
    }

    @Test func `should fail the stream when the screen won't start`() async throws {
        await #expect(throws: Refused.self) {
            try await run(try StreamCommand.parse(["--udid", "U"]), on: showing(try screen(failing: true)),
                          terminal: Terminal(lines: [], interrupted: true))
        }
    }

    @Test func `should exit 1 streaming a device with no screen`() async throws {
        let ran = try await run(try StreamCommand.parse(["--udid", "U"]), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do screen"])
    }

    // MARK: - logs

    private func logging(_ lines: [String], start failure: (any Error)? = nil) -> any Devices {
        let stream = MockLogStream()
        if let failure {
            given(stream).start(filter: .any, onLine: .any, onTerminate: .any).willThrow(failure)
        } else {
            given(stream).start(filter: .any, onLine: .any, onTerminate: .any).willProduce { _, onLine, onTerminate in
                lines.forEach(onLine)
                onTerminate(nil)
            }
        }
        given(stream).stop().willReturn()
        return routeDevices { $0.register(.logs) { stream } }
    }

    @Test(.timeLimit(.minutes(1)))
    func `should write each line the device logs until its log ends`() async throws {
        let ran = try await run(try LogsCommand.parse(["--udid", "U"]), on: logging(["first", "second"]))

        #expect(ran.exit == 0)
        #expect(String(decoding: ran.written, as: UTF8.self) == "first\nsecond\n")
    }

    @Test(.timeLimit(.minutes(1)))
    func `should end the logs when interrupted`() async throws {
        let stream = MockLogStream()
        given(stream).start(filter: .any, onLine: .any, onTerminate: .any).willReturn()
        given(stream).stop().willReturn()

        let ran = try await run(try LogsCommand.parse(["--udid", "U"]),
                                on: routeDevices { $0.register(.logs) { stream } },
                                terminal: Terminal(lines: [], interrupted: true))

        #expect(ran.exit == 0)
    }

    @Test func `should exit 1 when the device's log won't start`() async throws {
        let ran = try await run(try LogsCommand.parse(["--udid", "U"]),
                                on: logging([], start: LogStreamError.spawnFailed(reason: "no log")))

        #expect(ran.exit == 1)
        #expect(ran.told.first?.hasPrefix("logs: ") == true)
    }

    @Test func `should exit 1 naming the levels when the level is unknown`() async throws {
        let ran = try await run(try LogsCommand.parse(["--udid", "U", "--level", "loud"]), on: logging([]))

        #expect(ran.exit == 1)
        #expect(ran.told == ["logs: invalid --level 'loud' (use \(LogsCommand.levels))"])
    }

    @Test func `should exit 1 following the logs of a device without them`() async throws {
        let ran = try await run(try LogsCommand.parse(["--udid", "U"]), on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do logs"])
    }

    // MARK: - record

    @Test(.timeLimit(.minutes(1)))
    func `should exit 1 leaving no file when interrupted before any frame arrived`() async throws {
        let output = temporary("take.mp4")

        let ran = try await run(try RecordCommand.parse(["--udid", "U", "-o", output.path]),
                                on: showing(try screen(frame: false)),
                                terminal: Terminal(lines: [], interrupted: true))

        #expect(ran.exit == 1)
        #expect(ran.told == [RecordingError.noFramesCaptured.message])
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func `should end the take when its duration is up`() async throws {
        let ran = try await run(
            try RecordCommand.parse(["--udid", "U", "-o", temporary("take.mp4").path, "--duration", "0.05"]),
            on: showing(try screen(frame: false)))

        #expect(ran.exit == 1)
        #expect(ran.told == [RecordingError.noFramesCaptured.message])
    }

    @Test func `should exit 1 when the screen won't start recording`() async throws {
        let ran = try await run(try RecordCommand.parse(["--udid", "U", "-o", temporary("take.mp4").path]),
                                on: showing(try screen(failing: true)),
                                terminal: Terminal(lines: [], interrupted: true))

        #expect(ran.exit == 1)
        #expect(ran.told == ["Recording failed to start: refused"])
    }

    @Test func `should exit 1 recording a device with no screen`() async throws {
        let ran = try await run(try RecordCommand.parse(["--udid", "U", "-o", temporary("take.mp4").path]),
                                on: routeDevices())

        #expect(ran.exit == 1)
        #expect(ran.told == ["iPhone 17 can't do screen"])
    }
}
