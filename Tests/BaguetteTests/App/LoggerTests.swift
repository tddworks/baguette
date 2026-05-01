import Testing
@testable import Baguette

@Suite("Logger")
struct LoggerTests {

    // The function only writes to stderr; we don't intercept the FILE*
    // here — calling it just exercises the body so a future change that
    // crashes (e.g. dereferencing a nil format) gets caught.
    @Test func `log prints without throwing`() {
        log("test message")
        log("")
    }
}
