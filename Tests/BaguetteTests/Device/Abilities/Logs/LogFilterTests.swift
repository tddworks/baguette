import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("LogFilter")
struct LogFilterTests {

    // MARK: - level

    @Test func `should stream at info level by default`() {
        // Default = info — show everything except debug-level
        // chatter, but include the `default`-severity messages
        // most apps care about.
        #expect(LogFilter().level == .info)
    }

    @Test func `should accept default, info and debug as log levels`() {
        #expect(LogFilter.Level(wire: "default") == .default)
        #expect(LogFilter.Level(wire: "info")    == .info)
        #expect(LogFilter.Level(wire: "debug")   == .debug)
    }

    @Test func `should accept a log level in any case but reject levels the simulator log tool does not understand`() {
        #expect(LogFilter.Level(wire: "INFO") == .info)
        #expect(LogFilter.Level(wire: "Debug") == .debug)
        // notice / error / fault are accepted by macOS's host `log`
        // binary but not by the simulator's slimmer iOS one.
        #expect(LogFilter.Level(wire: "notice") == nil)
        #expect(LogFilter.Level(wire: "error") == nil)
        #expect(LogFilter.Level(wire: "fault") == nil)
        #expect(LogFilter.Level(wire: "trace") == nil)
        #expect(LogFilter.Level(wire: "") == nil)
    }

    // MARK: - style

    @Test func `should use the default log style by default`() {
        #expect(LogFilter().style == .default)
    }

    @Test func `should accept default, compact, json, syslog and ndjson as log styles`() {
        #expect(LogFilter.Style(wire: "default") == .default)
        #expect(LogFilter.Style(wire: "compact") == .compact)
        #expect(LogFilter.Style(wire: "json")    == .json)
        #expect(LogFilter.Style(wire: "syslog")  == .syslog)
        #expect(LogFilter.Style(wire: "ndjson")  == .ndjson)
    }

    // MARK: - args projection

    @Test func `should run log stream with the chosen --level and --style`() {
        let f = LogFilter(level: .debug, style: .json)
        // argv[0] = "log" because CoreSimulator's `arguments`
        // option replaces argv entirely (including argv[0]).
        #expect(f.argv == ["log", "stream", "--level", "debug", "--style", "json"])
    }

    @Test func `should run log stream at info level in the default style by default`() {
        #expect(LogFilter().argv == ["log", "stream", "--level", "info", "--style", "default"])
    }

    @Test func `should pass a raw --predicate through when one is given`() {
        let f = LogFilter(predicate: #"subsystem == "com.apple.UIKit""#)
        #expect(f.argv.contains("--predicate"))
        #expect(f.argv.last == #"subsystem == "com.apple.UIKit""#)
    }

    @Test func `should filter by process when a bundle id is given`() {
        let f = LogFilter(bundleId: "com.example.app")
        #expect(f.argv.contains("--predicate"))
        #expect(f.argv.last == #"process == "com.example.app""#)
    }

    @Test func `should combine a bundle id and a predicate with AND`() {
        let f = LogFilter(
            predicate: #"subsystem == "com.apple.UIKit""#,
            bundleId: "com.example.app"
        )
        // Both clauses appear in the final predicate, joined by AND.
        #expect(f.argv.contains("--predicate"))
        let predicate = f.argv.last ?? ""
        #expect(predicate.contains(#"subsystem == "com.apple.UIKit""#))
        #expect(predicate.contains(#"process == "com.example.app""#))
        #expect(predicate.contains(" AND "))
    }
}
