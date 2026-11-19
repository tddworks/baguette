import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// An Android SDK tool run as a child, with the child stood in for.
@Suite("AndroidTool")
struct AndroidToolTests {
    @Test func `should give up on a tool that doesn't answer in time, and stop it`() {
        let child = MockSubprocess()
        given(child).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any).willReturn()
        given(child).terminate().willReturn()
        let adb = AndroidTool(executable: URL(fileURLWithPath: "/sdk/adb"), timeout: 0.05, makeSubprocess: { child })

        #expect(throws: AdbError.timedOut) { try adb.runAndWait(["devices", "-l"]) }

        verify(child).terminate().called(1)
    }

    @Test func `should hand back what a tool printed when it answers in time`() throws {
        let child = MockSubprocess()
        given(child).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any)
            .willProduce { _, _, onBytes, onExit in
                onBytes(Data("List of devices attached\n".utf8))
                onExit(0)
            }
        let adb = AndroidTool(executable: URL(fileURLWithPath: "/sdk/adb"), timeout: 5, makeSubprocess: { child })

        #expect(try adb.runAndWait(["devices"]) == Data("List of devices attached\n".utf8))
    }
}
