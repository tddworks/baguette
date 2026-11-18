import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// `TerminalStyle` decides how a message appears on the way to stderr.
/// Pure string composition + a pure colour decision, so the `isatty`
/// call and the environment lookup stay at the call site in `Logger`.
@Suite("TerminalStyle")
struct TerminalStyleTests {

    private static let esc = "\u{001B}"

    // MARK: - Rendering

    @Test func `should wrap a coloured warning in yellow and reset after it`() {
        let rendered = TerminalStyle.warning("device will be lost", colored: true)
        #expect(rendered.hasPrefix("\(Self.esc)[33m"))
        #expect(rendered.hasSuffix("\(Self.esc)[0m"))
        #expect(rendered.contains("device will be lost"))
    }

    @Test func `should write a plain warning without any escape bytes`() {
        // Redirected output has to stay clean — a log file full of
        // escape sequences is worse than no colour.
        let rendered = TerminalStyle.warning("device will be lost", colored: false)
        #expect(!rendered.contains(Self.esc))
    }

    @Test func `should mark a warning as one even without colour`() {
        // Colour is the only cue a human gets on a terminal, but a
        // piped log has none — so the marker has to survive.
        let plain = TerminalStyle.warning("device will be lost", colored: false)
        #expect(plain.contains("warning:"))

        let coloured = TerminalStyle.warning("device will be lost", colored: true)
        #expect(coloured.contains("warning:"))
    }

    @Test func `should reset colour at the end of a multi-line warning`() {
        // The advisory wraps across lines; leaving the sequence open
        // would tint everything printed after it.
        let rendered = TerminalStyle.warning("first line\nsecond line", colored: true)
        #expect(rendered.hasSuffix("\(Self.esc)[0m"))
        #expect(rendered.contains("second line"))
    }

    // MARK: - Deciding whether to colour

    @Test func `should colour output on a terminal`() {
        #expect(TerminalStyle.shouldColorize(isTTY: true, environment: [:]) == true)
    }

    @Test func `should not colour redirected output`() {
        #expect(TerminalStyle.shouldColorize(isTTY: false, environment: [:]) == false)
    }

    @Test func `should not colour a terminal when NO_COLOR is set`() {
        // https://no-color.org — any non-empty value opts out.
        #expect(TerminalStyle.shouldColorize(
            isTTY: true, environment: ["NO_COLOR": "1"]
        ) == false)
    }

    @Test func `should ignore an empty NO_COLOR`() {
        // The convention is explicit that presence alone isn't enough;
        // the value must be non-empty.
        #expect(TerminalStyle.shouldColorize(
            isTTY: true, environment: ["NO_COLOR": ""]
        ) == true)
    }

    @Test func `should not colour a dumb terminal`() {
        #expect(TerminalStyle.shouldColorize(
            isTTY: true, environment: ["TERM": "dumb"]
        ) == false)
    }

    @Test func `should keep colour on an ordinary TERM`() {
        #expect(TerminalStyle.shouldColorize(
            isTTY: true, environment: ["TERM": "xterm-256color"]
        ) == true)
    }
}
