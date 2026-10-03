import ArgumentParser
import Mockable
import Testing

@testable import Baguette

@Suite("ExistingDisplay")
struct ExistingDisplayTests {
    @Test func `explicit input flag disables implicit CarPlay attachment`() throws {
        let command = try InputCommand.parse(["--udid", "SIM", "--display", "carplay", "--require-existing-display"])
        #expect(command.requireExistingDisplay)
        let plan = try StreamDisplayPlan.from(
            cliFlag: command.display, requireExistingDisplay: command.requireExistingDisplay)
        #expect(plan.kind == .carPlay)
        #expect(!plan.enableCarPlay)
    }

    @Test func `existing display query is strict and does not alter the upstream default`() throws {
        #expect(try !StreamDisplayPlan.requireExistingDisplay(query: []))
        #expect(try StreamDisplayPlan.requireExistingDisplay(query: ["1"]))
        #expect(throws: (any Error).self) { try StreamDisplayPlan.requireExistingDisplay(query: ["true"]) }
        #expect(throws: (any Error).self) { try StreamDisplayPlan.requireExistingDisplay(query: ["1", "1"]) }
        #expect(StreamDisplayPlan.from(query: "carplay", requireExistingDisplay: true).enableCarPlay == false)
        #expect(StreamDisplayPlan.from(query: "carplay").enableCarPlay == true)
    }

    @Test func `an absent required CarPlay screen never opens Simulator menus or substitutes the phone`() throws {
        let sim = MockSimulator()
        let displays = MockDisplays()
        let display = MockDisplay()
        given(sim).displays().willReturn(displays)
        given(displays).carPlay.willReturn(display)
        given(display).resolve().willThrow(FramebufferSelectionError.noMatchingPort(.carPlay))
        let plan = try StreamDisplayPlan.from(cliFlag: "carplay", requireExistingDisplay: true)
        #expect(throws: FramebufferSelectionError.noMatchingPort(.carPlay)) { try plan.bind(to: sim) }
        verify(sim).externalDisplays().called(0)
        verify(display).screen().called(0)
        verify(display).input().called(0)
        verify(sim).screen().called(0)
        verify(sim).input().called(0)
    }
}
