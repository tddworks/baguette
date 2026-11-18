import Testing
import ArgumentParser
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Argv wiring + validation for `baguette record`. `run()` talks to
/// CoreSimulators, AVFoundation and signals, so it stays integration-only
/// — these tests pin what the user is allowed to type and what they're
/// told when they type something baguette can't record.
@Suite("RecordCommand")
struct RecordCommandTests {

    private let minimum = ["--udid", "U", "--output", "/tmp/demo.mp4"]

    @Test func `should record at the simulator's own size and 30 fps by default`() throws {
        let cmd = try RecordCommand.parse(minimum)

        #expect(cmd.options.udid == "U")
        #expect(cmd.output == "/tmp/demo.mp4")
        #expect(cmd.size == "native")
        #expect(cmd.fit == "contain")
        #expect(cmd.background == "#ffffff")
        #expect(cmd.fps == 30)
        #expect(cmd.duration == nil)
        #expect(cmd.bitrate == 8_000_000)
        #expect(RecordCommand.configuration.commandName == "record")
    }

    @Test func `should take an App Store size, fit, duration, background, fps and bitrate`() throws {
        let cmd = try RecordCommand.parse(minimum + [
            "--size", "appstore-6.9", "--fit", "cover", "--duration", "7.5",
            "--background", "#101820", "--fps", "60", "--bitrate", "12000000",
        ])

        #expect(cmd.size == "appstore-6.9")
        #expect(cmd.fit == "cover")
        #expect(cmd.duration == 7.5)
        #expect(cmd.background == "#101820")
        #expect(cmd.fps == 60)
        #expect(cmd.bitrate == 12_000_000)
    }

    @Test func `should accept -o as the short spelling of --output`() throws {
        let cmd = try RecordCommand.parse(["--udid", "U", "-o", "/tmp/clip.mov"])
        #expect(cmd.output == "/tmp/clip.mov")
    }

    // MARK: - Validation

    private func failure(_ argv: [String]) -> String? {
        do {
            var cmd = try RecordCommand.parse(argv)
            try cmd.validate()
            return nil
        } catch {
            return "\(error)"
        }
    }

    @Test func `should name every known size when --size is unknown`() throws {
        let message = try #require(failure(minimum + ["--size", "nonsense"]))
        #expect(message.contains("Unknown size 'nonsense'"))
        #expect(message.contains("appstore-6.9"))
    }

    @Test func `should reject an unwritable container before the simulator is touched`() throws {
        let message = try #require(
            failure(["--udid", "U", "--output", "/tmp/demo.webm"])
        )
        #expect(message.contains("Unknown recording container 'webm'"))
    }

    @Test func `should reject a transparent background because video has no alpha`() throws {
        let message = try #require(failure(minimum + ["--background", "transparent"]))
        #expect(message.contains("--background must be #RRGGBB"))
    }

    @Test func `should reject an unrecordable --fps`() {
        #expect(failure(minimum + ["--fps", "0"]) != nil)
        #expect(failure(minimum + ["--fps", "240"]) != nil)
        #expect(failure(minimum + ["--fps", "60"]) == nil)
    }

    @Test func `should reject a --duration that is not a positive length of time`() {
        #expect(failure(minimum + ["--duration", "0"]) != nil)
        #expect(failure(minimum + ["--duration", "-3"]) != nil)
    }

    @Test func `should name the three known fits when --fit is unknown`() throws {
        let message = try #require(failure(minimum + ["--fit", "squish"]))
        #expect(message.contains("contain"))
        #expect(message.contains("cover"))
        #expect(message.contains("stretch"))
    }

    @Test func `should accept --fit and --background in any case, as --size is`() throws {
        // `--size SQUARE` already works, because `CaptureSize.parse`
        // lowercases; a sibling flag that rejected `--fit COVER` on the
        // same command line would be arbitrary. `screenshot` normalises
        // both, so `record` does too.
        var cmd = try RecordCommand.parse(minimum + [
            "--fit", "COVER", "--background", "#AABBCC", "--size", "SQUARE",
        ])
        try cmd.validate()

        #expect(cmd.fit == "cover")
        #expect(cmd.background == "#aabbcc")
    }

    @Test func `should accept every known size, fit and container`() throws {
        for preset in CaptureSize.presets {
            #expect(failure(minimum + ["--size", preset.spec]) == nil)
        }
        for fit in CaptureFit.allCases {
            #expect(failure(minimum + ["--fit", fit.rawValue]) == nil)
        }
        for container in RecordingFormat.allCases {
            #expect(failure(["--udid", "U", "-o", "/tmp/demo.\(container.rawValue)"]) == nil)
        }
        #expect(failure(minimum + ["--size", "1920x1080"]) == nil)
        #expect(failure(minimum + ["--size", "3:2"]) == nil)
    }
}
