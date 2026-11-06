import Testing
import Foundation
@testable import Baguette

@Suite("Logger")
struct LoggerTests {

    // The function only writes to stderr; we don't intercept the FILE*
    // here — calling it just exercises the body so a future change that
    // crashes (e.g. dereferencing a nil format) gets caught.
    @Test func `should print a log line without crashing`() {
        log("test message")
        log("")
    }

    // Same deal as `log` — the styling decision is covered in
    // TerminalStyleTests; this just exercises the write path.
    @Test func `should print a warning without crashing`() {
        warn("test warning")
        warn("")
    }

    @Test func `should stay silent about progress when verbose isn't asked for`() {
        #expect(Trace.isOn(environment: [:]) == false)
        #expect(Trace.isOn(environment: ["BAGUETTE_VERBOSE": "0"]) == false)
        #expect(Trace.isOn(environment: ["BAGUETTE_VERBOSE": ""]) == false)
    }

    @Test func `should report progress when verbose is asked for`() {
        #expect(Trace.isOn(environment: ["BAGUETTE_VERBOSE": "1"]) == true)
    }

    @Test func `should not colour output when stderr is not a terminal`() {
        // -1 is never a tty, so this is deterministic. Asserting on
        // STDERR_FILENO would not be: `swift test` inherits the parent's
        // stderr, which is a terminal when run interactively and a pipe
        // in CI, so the expected value would flip with the environment.
        #expect(terminalColorized(-1) == false)
    }
}
