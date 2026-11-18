import Testing
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// Default-impl behaviour on `InputSurface`: `heal` is the one verb the
/// App layer calls — after a boot, or on `baguette heal` — and it only
/// pays for the SpringBoard restart when the surface is actually shadowed.
@Suite("InputSurface")
struct InputSurfaceTests {

    @Test func `should leave an unshadowed input surface alone when healing`() async throws {
        let surface = MockInputSurface()
        let sim = MockSimulator()
        given(surface).shadowed().willReturn(false)

        let outcome = try await surface.heal()

        #expect(outcome == .unshadowed)
        verify(surface).reclaim().called(0)
    }

    @Test func `should reclaim a shadowed input surface when healing`() async throws {
        let surface = MockInputSurface()
        let sim = MockSimulator()
        given(surface).shadowed().willReturn(true)
        given(surface).reclaim().willReturn()

        let outcome = try await surface.heal()

        #expect(outcome == .reclaimed)
        verify(surface).reclaim().called(1)
    }

    @Test func `should report a failed reclaim when healing`() async {
        let surface = MockInputSurface()
        let sim = MockSimulator()
        given(surface).shadowed().willReturn(true)
        given(surface).reclaim().willThrow(InputSurfaceError.springBoardMissing)

        await #expect(throws: InputSurfaceError.springBoardMissing) {
            try await surface.heal()
        }
    }

    @Test func `should wait for the input surface to be ready when healing after boot`() async throws {
        let surface = MockInputSurface()
        let sim = MockSimulator()
        given(surface).ready().willReturn()
        given(surface).shadowed().willReturn(true)
        given(surface).reclaim().willReturn()

        let outcome = try await surface.healAfterBoot()

        #expect(outcome == .reclaimed)
        verify(surface).ready().called(1)
    }

    @Test func `should summarise each heal outcome in one line`() {
        #expect(HealOutcome.unshadowed.summary.contains("not shadowed"))
        #expect(HealOutcome.reclaimed.summary.contains("reclaimed"))
    }
}
