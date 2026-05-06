import Testing
import ArgumentParser
@testable import Baguette

/// Parses each subcommand from argv and asserts the @Option/@OptionGroup
/// wiring + CommandConfiguration metadata. `run()` itself talks to
/// CoreSimulators / stdin / signals, so it stays out of coverage by
/// design — these tests only pin the structure.
@Suite("CommandParsing")
struct CommandParsingTests {

    // MARK: - root

    @Test func `baguette root lists every subcommand`() {
        let cfg = Baguette.configuration
        #expect(cfg.commandName == "baguette")
        let names = cfg.subcommands.map { $0.configuration.commandName }
        #expect(Set(names) == [
            "list", "boot", "shutdown", "input", "stream",
            "tap", "swipe", "pinch", "pan", "press",
            "key", "type",
            "chrome", "screenshot", "describe-ui", "logs", "serve",
        ])
    }

    @Test func `baguette root exposes version`() {
        #expect(Baguette.configuration.version == baguetteVersion)
        #expect(!baguetteVersion.isEmpty)
    }

    // MARK: - list

    @Test func `list parses --device-set`() throws {
        let cmd = try ListCommand.parse(["--device-set", "/tmp/set"])
        #expect(cmd.deviceSet == "/tmp/set")
        #expect(ListCommand.configuration.commandName == "list")
    }

    @Test func `list defaults device-set to nil`() throws {
        let cmd = try ListCommand.parse([])
        #expect(cmd.deviceSet == nil)
        #expect(cmd.json == false)
    }

    @Test func `list parses --json flag`() throws {
        let cmd = try ListCommand.parse(["--json"])
        #expect(cmd.json == true)
    }

    // MARK: - boot / shutdown share DeviceOption

    @Test func `boot requires --udid`() throws {
        let cmd = try BootCommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(cmd.options.deviceSet == nil)
        #expect(BootCommand.configuration.commandName == "boot")
    }

    @Test func `boot rejects argv without --udid`() {
        #expect(throws: (any Error).self) {
            try BootCommand.parse([])
        }
    }

    @Test func `shutdown carries udid + device-set`() throws {
        let cmd = try ShutdownCommand.parse([
            "--udid", "XYZ", "--device-set", "/var/sims",
        ])
        #expect(cmd.options.udid == "XYZ")
        #expect(cmd.options.deviceSet == "/var/sims")
        #expect(ShutdownCommand.configuration.commandName == "shutdown")
    }

    // MARK: - input

    @Test func `input parses --udid`() throws {
        let cmd = try InputCommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(InputCommand.configuration.commandName == "input")
    }

    // MARK: - stream

    @Test func `stream defaults match StreamConfig.default`() throws {
        let cmd = try StreamCommand.parse(["--udid", "ABC"])
        #expect(cmd.format == "mjpeg")
        #expect(cmd.fps == 60)
        #expect(cmd.quality == 0.70)
        #expect(cmd.bitrate == StreamConfig.default.bitrateBps)
        #expect(cmd.scale == StreamConfig.default.scale)
        #expect(StreamCommand.configuration.commandName == "stream")
    }

    @Test func `stream accepts every tunable knob`() throws {
        let cmd = try StreamCommand.parse([
            "--udid", "ABC",
            "--format", "avcc",
            "--fps", "30",
            "--quality", "0.9",
            "--bitrate", "8000000",
            "--scale", "2",
        ])
        #expect(cmd.format == "avcc")
        #expect(cmd.fps == 30)
        #expect(cmd.quality == 0.9)
        #expect(cmd.bitrate == 8_000_000)
        #expect(cmd.scale == 2)
    }

    // MARK: - gesture commands

    @Test func `tap parses point + size + duration`() throws {
        let cmd = try TapCommand.parse([
            "--udid", "ABC",
            "--x", "10", "--y", "20",
            "--width", "390", "--height", "844",
            "--duration", "0.1",
        ])
        #expect(cmd.x == 10 && cmd.y == 20)
        #expect(cmd.width == 390 && cmd.height == 844)
        #expect(cmd.duration == 0.1)
        #expect(TapCommand.configuration.commandName == "tap")
    }

    @Test func `tap duration defaults to 0.05`() throws {
        let cmd = try TapCommand.parse([
            "--udid", "ABC",
            "--x", "1", "--y", "2",
            "--width", "390", "--height", "844",
        ])
        #expect(cmd.duration == 0.05)
    }

    @Test func `swipe parses start + end + size`() throws {
        let cmd = try SwipeCommand.parse([
            "--udid", "ABC",
            "--start-x", "0", "--start-y", "0",
            "--end-x", "100", "--end-y", "200",
            "--width", "390", "--height", "844",
        ])
        #expect(cmd.startX == 0 && cmd.startY == 0)
        #expect(cmd.endX == 100 && cmd.endY == 200)
        #expect(cmd.duration == 0.25)
        #expect(SwipeCommand.configuration.commandName == "swipe")
    }

    @Test func `pinch parses centre + spread`() throws {
        let cmd = try PinchCommand.parse([
            "--udid", "ABC",
            "--cx", "100", "--cy", "200",
            "--start-spread", "50", "--end-spread", "150",
            "--width", "390", "--height", "844",
        ])
        #expect(cmd.cx == 100 && cmd.cy == 200)
        #expect(cmd.startSpread == 50 && cmd.endSpread == 150)
        #expect(cmd.duration == 0.6)
        #expect(PinchCommand.configuration.commandName == "pinch")
    }

    @Test func `pan parses two contacts + delta`() throws {
        let cmd = try PanCommand.parse([
            "--udid", "ABC",
            "--x1", "10", "--y1", "20",
            "--x2", "30", "--y2", "40",
            "--dx", "5", "--dy=-5",
            "--width", "390", "--height", "844",
        ])
        #expect(cmd.x1 == 10 && cmd.y1 == 20)
        #expect(cmd.x2 == 30 && cmd.y2 == 40)
        #expect(cmd.dx == 5 && cmd.dy == -5)
        #expect(cmd.duration == 0.5)
        #expect(PanCommand.configuration.commandName == "pan")
    }

    @Test func `press parses --button`() throws {
        let cmd = try PressCommand.parse(["--udid", "ABC", "--button", "home"])
        #expect(cmd.button == "home")
        #expect(PressCommand.configuration.commandName == "press")
    }

    // MARK: - screenshot

    @Test func `screenshot defaults match snapshot helper`() throws {
        let cmd = try ScreenshotCommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(cmd.output == nil)
        #expect(cmd.quality == 0.85)
        #expect(cmd.scale == 1)
        #expect(ScreenshotCommand.configuration.commandName == "screenshot")
    }

    @Test func `screenshot accepts --output --quality --scale`() throws {
        let cmd = try ScreenshotCommand.parse([
            "--udid", "ABC",
            "--output", "/tmp/x.jpg",
            "--quality", "0.5",
            "--scale", "2",
        ])
        #expect(cmd.output == "/tmp/x.jpg")
        #expect(cmd.quality == 0.5)
        #expect(cmd.scale == 2)
    }

    // MARK: - describe-ui

    @Test func `describe-ui requires --udid and defaults to full tree`() throws {
        let cmd = try DescribeUICommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(cmd.x == nil && cmd.y == nil)
        #expect(cmd.output == nil)
        #expect(DescribeUICommand.configuration.commandName == "describe-ui")
    }

    @Test func `describe-ui accepts --x --y --output`() throws {
        let cmd = try DescribeUICommand.parse([
            "--udid", "ABC",
            "--x", "120", "--y", "400",
            "--output", "/tmp/tree.json",
        ])
        #expect(cmd.x == 120 && cmd.y == 400)
        #expect(cmd.output == "/tmp/tree.json")
    }

    // MARK: - logs

    @Test func `logs requires --udid and defaults level + style`() throws {
        let cmd = try LogsCommand.parse(["--udid", "ABC"])
        #expect(cmd.options.udid == "ABC")
        #expect(cmd.level == "info")
        #expect(cmd.style == "default")
        #expect(cmd.predicate == nil)
        #expect(cmd.bundleId == nil)
        #expect(LogsCommand.configuration.commandName == "logs")
    }

    @Test func `logs accepts --level --style --predicate --bundle-id`() throws {
        let cmd = try LogsCommand.parse([
            "--udid", "ABC",
            "--level", "debug",
            "--style", "json",
            "--predicate", #"subsystem == "com.apple.UIKit""#,
            "--bundle-id", "com.example.app",
        ])
        #expect(cmd.level == "debug")
        #expect(cmd.style == "json")
        #expect(cmd.predicate == #"subsystem == "com.apple.UIKit""#)
        #expect(cmd.bundleId == "com.example.app")
    }

    // MARK: - serve

    @Test func `serve defaults bind to 127.0.0.1:8421`() throws {
        let cmd = try ServeCommand.parse([])
        #expect(cmd.host == "127.0.0.1")
        #expect(cmd.port == 8421)
        #expect(cmd.deviceSet == nil)
        #expect(ServeCommand.configuration.commandName == "serve")
    }

    @Test func `serve overrides host + port + device-set`() throws {
        let cmd = try ServeCommand.parse([
            "--host", "0.0.0.0",
            "--port", "9000",
            "--device-set", "/tmp/sims",
        ])
        #expect(cmd.host == "0.0.0.0")
        #expect(cmd.port == 9000)
        #expect(cmd.deviceSet == "/tmp/sims")
    }
}
