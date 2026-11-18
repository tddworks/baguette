import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// `LineBuffer` accumulates byte chunks from a streaming pipe and
/// pops out complete `\n`-terminated UTF-8 lines on each append.
/// Anything past the last `\n` is held for the next append. Used
/// by `SimDeviceLogStream` to split `xcrun simctl spawn`'s stdout
/// into log entries; behaviour is independent of the spawn so
/// it's easy to drive deterministically here.
@Suite("LineBuffer")
struct LineBufferTests {

    // MARK: - basic line splitting

    @Test func `should split one complete line into one log line`() {
        var buf = LineBuffer()
        let lines = buf.append(Data("hello\n".utf8))
        #expect(lines == ["hello"])
        #expect(buf.leftover.isEmpty)
    }

    @Test func `should split two complete lines arriving together into two log lines`() {
        var buf = LineBuffer()
        let lines = buf.append(Data("hello\nworld\n".utf8))
        #expect(lines == ["hello", "world"])
        #expect(buf.leftover.isEmpty)
    }

    // MARK: - partial / multi-append behaviour

    @Test func `should hold bytes without a newline until the rest of the line arrives`() {
        var buf = LineBuffer()
        let lines1 = buf.append(Data("partial".utf8))
        #expect(lines1.isEmpty)
        #expect(buf.leftover == Data("partial".utf8))

        let lines2 = buf.append(Data(" line\n".utf8))
        #expect(lines2 == ["partial line"])
        #expect(buf.leftover.isEmpty)
    }

    @Test func `should hold a trailing partial line until the rest arrives`() {
        var buf = LineBuffer()
        let lines1 = buf.append(Data("first\nseco".utf8))
        #expect(lines1 == ["first"])
        #expect(buf.leftover == Data("seco".utf8))

        let lines2 = buf.append(Data("nd\n".utf8))
        #expect(lines2 == ["second"])
    }

    @Test func `should yield no lines and keep the partial line when no bytes arrive`() {
        var buf = LineBuffer()
        _ = buf.append(Data("abc".utf8))
        let lines = buf.append(Data())
        #expect(lines.isEmpty)
        #expect(buf.leftover == Data("abc".utf8))
    }

    // MARK: - corner cases

    @Test func `should yield an empty log line for consecutive newlines`() {
        var buf = LineBuffer()
        let lines = buf.append(Data("a\n\nb\n".utf8))
        #expect(lines == ["a", "", "b"])
    }

    @Test func `should yield one empty log line for a lone newline`() {
        var buf = LineBuffer()
        let lines = buf.append(Data("\n".utf8))
        #expect(lines == [""])
    }

    @Test func `should silently drop a line that is not valid UTF-8`() {
        var buf = LineBuffer()
        // 0xFF is invalid UTF-8 lead byte. Sandwich it with valid
        // lines so we can confirm only the bad line is dropped.
        var bytes = Data("ok-1\n".utf8)
        bytes.append(Data([0xFF, 0x0A]))      // bad line + \n
        bytes.append(Data("ok-2\n".utf8))
        let lines = buf.append(bytes)
        #expect(lines == ["ok-1", "ok-2"])
    }

    // MARK: - mid-line CR / large input

    @Test func `should keep carriage returns inside a line verbatim`() {
        var buf = LineBuffer()
        let lines = buf.append(Data("with\rcarriage\n".utf8))
        #expect(lines == ["with\rcarriage"])
    }
}
