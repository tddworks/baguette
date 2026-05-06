import Testing
@testable import Baguette

@Suite("LogFilter")
struct LogFilterTests {

    // MARK: - level

    @Test func `default level is info`() {
        // Default = info — show everything except debug-level
        // chatter, but include the `default`-severity messages
        // most apps care about.
        #expect(LogFilter().level == .info)
    }

    @Test func `Level.fromWire parses every supported value`() {
        #expect(LogFilter.Level(wire: "default") == .default)
        #expect(LogFilter.Level(wire: "info")    == .info)
        #expect(LogFilter.Level(wire: "debug")   == .debug)
    }

    @Test func `Level.fromWire rejects values the simulator log binary doesn't understand`() {
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

    @Test func `default style is default`() {
        #expect(LogFilter().style == .default)
    }

    @Test func `Style.fromWire covers every supported value`() {
        #expect(LogFilter.Style(wire: "default") == .default)
        #expect(LogFilter.Style(wire: "compact") == .compact)
        #expect(LogFilter.Style(wire: "json")    == .json)
        #expect(LogFilter.Style(wire: "syslog")  == .syslog)
        #expect(LogFilter.Style(wire: "ndjson")  == .ndjson)
    }

    // MARK: - args projection

    @Test func `argv projects level + style flags`() {
        let f = LogFilter(level: .debug, style: .json)
        // argv[0] = "log" because CoreSimulator's `arguments`
        // option replaces argv entirely (including argv[0]).
        #expect(f.argv == ["log", "stream", "--level", "debug", "--style", "json"])
    }

    @Test func `argv defaults emit info + default`() {
        #expect(LogFilter().argv == ["log", "stream", "--level", "info", "--style", "default"])
    }

    @Test func `argv appends raw predicate when present`() {
        let f = LogFilter(predicate: #"subsystem == "com.apple.UIKit""#)
        #expect(f.argv.contains("--predicate"))
        #expect(f.argv.last == #"subsystem == "com.apple.UIKit""#)
    }

    @Test func `argv translates bundle-id into a process predicate`() {
        let f = LogFilter(bundleId: "com.example.app")
        #expect(f.argv.contains("--predicate"))
        #expect(f.argv.last == #"process == "com.example.app""#)
    }

    @Test func `argv ANDs bundle-id with explicit predicate`() {
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
