import Testing
import Foundation
@testable import Baguette

/// `LineBuffer` accumulates byte chunks from a streaming pipe and
/// pops out complete `\n`-terminated UTF-8 lines on each append.
/// Anything past the last `\n` is held for the next append. Used
/// by `SimDeviceLogStream` to split `xcrun simctl spawn`'s stdout
/// into log entries; behaviour is independent of the spawn so
/// it's easy to drive deterministically here.
@Suite("LineBuffer")
struct LineBufferTests {

    // MARK: - basic line splitting

    @Test func `single complete line yields one string`() {
        var buf = LineBuffer()
        let lines = buf.append(Data("hello\n".utf8))
        #expect(lines == ["hello"])
        #expect(buf.leftover.isEmpty)
    }

    @Test func `two complete lines in one append yield two strings`() {
        var buf = LineBuffer()
        let lines = buf.append(Data("hello\nworld\n".utf8))
        #expect(lines == ["hello", "world"])
        #expect(buf.leftover.isEmpty)
    }

    // MARK: - partial / multi-append behaviour

    @Test func `bytes without a newline are buffered for next append`() {
        var buf = LineBuffer()
        let lines1 = buf.append(Data("partial".utf8))
        #expect(lines1.isEmpty)
        #expect(buf.leftover == Data("partial".utf8))

        let lines2 = buf.append(Data(" line\n".utf8))
        #expect(lines2 == ["partial line"])
        #expect(buf.leftover.isEmpty)
    }

    @Test func `trailing partial after newline is held until the next append`() {
        var buf = LineBuffer()
        let lines1 = buf.append(Data("first\nseco".utf8))
        #expect(lines1 == ["first"])
        #expect(buf.leftover == Data("seco".utf8))

        let lines2 = buf.append(Data("nd\n".utf8))
        #expect(lines2 == ["second"])
    }

    @Test func `empty append returns no lines and doesn't disturb leftover`() {
        var buf = LineBuffer()
        _ = buf.append(Data("abc".utf8))
        let lines = buf.append(Data())
        #expect(lines.isEmpty)
        #expect(buf.leftover == Data("abc".utf8))
    }

    // MARK: - corner cases

    @Test func `consecutive newlines yield an empty-string line`() {
        var buf = LineBuffer()
        let lines = buf.append(Data("a\n\nb\n".utf8))
        #expect(lines == ["a", "", "b"])
    }

    @Test func `lone newline yields one empty line`() {
        var buf = LineBuffer()
        let lines = buf.append(Data("\n".utf8))
        #expect(lines == [""])
    }

    @Test func `non-UTF8 line bytes are dropped silently`() {
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

    @Test func `bytes with embedded CR are kept verbatim before the LF split`() {
        var buf = LineBuffer()
        let lines = buf.append(Data("with\rcarriage\n".utf8))
        #expect(lines == ["with\rcarriage"])
    }
}
