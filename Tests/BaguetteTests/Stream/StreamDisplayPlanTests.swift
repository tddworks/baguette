import Testing
import Foundation
import Mockable
@testable import Baguette

/// A stream session binds to a display kind from the `display` query
/// (`phone`|`carplay`, default phone). CarPlay plans ask to enable the
/// external panel first; phone plans do not.
@Suite("StreamDisplayPlan")
struct StreamDisplayPlanTests {

    @Test func `nil or empty query defaults to phone without enabling CarPlay`() {
        #expect(StreamDisplayPlan.from(query: nil) == StreamDisplayPlan(
            kind: .phone, enableCarPlay: false
        ))
        #expect(StreamDisplayPlan.from(query: "") == StreamDisplayPlan(
            kind: .phone, enableCarPlay: false
        ))
    }

    @Test func `phone query yields phone without enabling CarPlay`() {
        #expect(StreamDisplayPlan.from(query: "phone") == StreamDisplayPlan(
            kind: .phone, enableCarPlay: false
        ))
        #expect(StreamDisplayPlan.from(query: "PHONE") == StreamDisplayPlan(
            kind: .phone, enableCarPlay: false
        ))
    }

    @Test func `carplay query yields carPlay and asks to enable the panel`() {
        #expect(StreamDisplayPlan.from(query: "carplay") == StreamDisplayPlan(
            kind: .carPlay, enableCarPlay: true
        ))
        #expect(StreamDisplayPlan.from(query: "CarPlay") == StreamDisplayPlan(
            kind: .carPlay, enableCarPlay: true
        ))
    }

    @Test func `unknown query defaults to phone without enabling CarPlay`() {
        #expect(StreamDisplayPlan.from(query: "tv") == StreamDisplayPlan(
            kind: .phone, enableCarPlay: false
        ))
    }

    @Test func `phoneOnly forces the phone plane for 3D routes`() {
        #expect(StreamDisplayPlan.phoneOnly == StreamDisplayPlan(
            kind: .phone, enableCarPlay: false
        ))
    }
}

/// Opening a planned stream enables CarPlay when asked, then takes
/// screen and input from that display aggregate only. Phone stays on
/// the legacy aliases; CarPlay uses `displays().carPlay`.
@Suite("StreamDisplayPlan.bind")
struct StreamDisplayPlanBindTests {

    @Test func `phone bind uses legacy screen and input without touching external displays`() throws {
        let sim = MockSimulator()
        let screen = MockScreen()
        let input = MockInput()
        given(sim).screen().willReturn(screen)
        given(sim).input().willReturn(input)

        let bound = try StreamDisplayPlan(kind: .phone, enableCarPlay: false).bind(to: sim)

        #expect(bound.screen as? MockScreen === screen)
        #expect(bound.input as? MockInput === input)
        verify(sim).externalDisplays().called(0)
        verify(sim).displays().called(0)
    }

    @Test func `carPlay bind enables the panel then takes screen and input from the carPlay display`() throws {
        let sim = MockSimulator()
        let external = MockExternalDisplays()
        let displays = MockDisplays()
        let carPlay = MockDisplay()
        let screen = MockScreen()
        let input = MockInput()
        let binding = DisplayBinding(
            kind: .carPlay,
            connectedScreenId: 2,
            portName: "com.apple.framebuffer.display",
            size: Size(width: 800, height: 480)
        )
        given(sim).externalDisplays().willReturn(external)
        given(external).enableCarPlay().willReturn(())
        given(sim).displays().willReturn(displays)
        given(displays).carPlay.willReturn(carPlay)
        given(carPlay).resolve().willReturn(binding)
        given(carPlay).screen().willReturn(screen)
        given(carPlay).input().willReturn(input)

        let bound = try StreamDisplayPlan(kind: .carPlay, enableCarPlay: true).bind(to: sim)

        #expect(bound.screen as? MockScreen === screen)
        #expect(bound.input as? MockInput === input)
        verify(external).enableCarPlay().called(1)
        verify(carPlay).resolve().called(1)
        verify(sim).screen().called(0)
        verify(sim).input().called(0)
    }

    @Test func `carPlay bind fails closed when the carPlay plane cannot resolve`() {
        let sim = MockSimulator()
        let external = MockExternalDisplays()
        let displays = MockDisplays()
        let carPlay = MockDisplay()
        given(sim).externalDisplays().willReturn(external)
        given(external).enableCarPlay().willReturn(())
        given(sim).displays().willReturn(displays)
        given(displays).carPlay.willReturn(carPlay)
        given(carPlay).resolve().willThrow(FramebufferSelectionError.noMatchingPort(.carPlay))

        #expect(throws: FramebufferSelectionError.noMatchingPort(.carPlay)) {
            try StreamDisplayPlan(kind: .carPlay, enableCarPlay: true).bind(to: sim)
        }
        verify(carPlay).screen().called(0)
        verify(carPlay).input().called(0)
    }

    @Test func `carPlay bind surfaces enableCarPlay failures`() {
        let sim = MockSimulator()
        let external = MockExternalDisplays()
        given(sim).externalDisplays().willReturn(external)
        given(external).enableCarPlay().willThrow(CarPlayEnableError.panelUnavailable)

        #expect(throws: CarPlayEnableError.panelUnavailable) {
            try StreamDisplayPlan(kind: .carPlay, enableCarPlay: true).bind(to: sim)
        }
        verify(sim).displays().called(0)
    }
}

/// CLI flags are strict where the WS query is forgiving: a typo'd
/// `--display carply` must fail the invocation, never silently capture
/// or touch the phone plane instead.
@Suite("StreamDisplayPlan.fromCLI")
struct StreamDisplayPlanFromCLITests {

    @Test func `absent flag yields phone without enabling CarPlay`() throws {
        #expect(try StreamDisplayPlan.from(cliFlag: nil) == StreamDisplayPlan(
            kind: .phone, enableCarPlay: false
        ))
    }

    @Test func `phone flag yields phone without enabling CarPlay`() throws {
        #expect(try StreamDisplayPlan.from(cliFlag: "phone") == StreamDisplayPlan(
            kind: .phone, enableCarPlay: false
        ))
    }

    @Test func `carplay flag yields carPlay and asks to enable the panel`() throws {
        #expect(try StreamDisplayPlan.from(cliFlag: "carplay") == StreamDisplayPlan(
            kind: .carPlay, enableCarPlay: true
        ))
        #expect(try StreamDisplayPlan.from(cliFlag: "CARPLAY") == StreamDisplayPlan(
            kind: .carPlay, enableCarPlay: true
        ))
    }

    @Test func `unknown flag is rejected, not downgraded to phone`() {
        #expect(throws: DisplayFlagError.unknown("carply")) {
            try StreamDisplayPlan.from(cliFlag: "carply")
        }
    }

    /// The rejection is what the operator actually reads, so the wording is
    /// part of the contract: it has to name the planes that would have
    /// worked and echo the token that didn't, or a typo costs a round trip
    /// to the docs to spot.
    @Test func `the rejection names both planes and echoes what was typed`() {
        #expect(
            DisplayFlagError.unknown("carply").message
            == #"--display must be one of: phone, carplay (got "carply")"#
        )
    }

    @Test func `the rejection echoes an empty-looking token verbatim`() {
        #expect(
            DisplayFlagError.unknown(" ").message
            == #"--display must be one of: phone, carplay (got " ")"#
        )
    }
}

/// Domain error for host panel enablement failures — tests need a
/// concrete Error; Infra will map AppleScript failures onto this later.
enum CarPlayEnableError: Error, Equatable {
    case panelUnavailable
}
