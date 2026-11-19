import Testing
import Foundation
import Mockable
@testable import Baguette
@testable import BaguetteDevice

/// A stream session binds to a display kind from the `display` query
/// (`phone`|`carplay`, default phone). CarPlay plans ask to enable the
/// external panel first; phone plans do not.
@Suite("StreamDisplayPlan")
struct StreamDisplayPlanTests {

    @Test func `should stream the phone without enabling CarPlay when the display query is absent or empty`() {
        #expect(StreamDisplayPlan.from(query: nil) == StreamDisplayPlan(
            kind: .phone, enableCarPlay: false
        ))
        #expect(StreamDisplayPlan.from(query: "") == StreamDisplayPlan(
            kind: .phone, enableCarPlay: false
        ))
    }

    @Test func `should stream the phone without enabling CarPlay when the display query is phone`() {
        #expect(StreamDisplayPlan.from(query: "phone") == StreamDisplayPlan(
            kind: .phone, enableCarPlay: false
        ))
        #expect(StreamDisplayPlan.from(query: "PHONE") == StreamDisplayPlan(
            kind: .phone, enableCarPlay: false
        ))
    }

    @Test func `should stream CarPlay and enable its panel when the display query is carplay`() {
        #expect(StreamDisplayPlan.from(query: "carplay") == StreamDisplayPlan(
            kind: .carPlay, enableCarPlay: true
        ))
        #expect(StreamDisplayPlan.from(query: "CarPlay") == StreamDisplayPlan(
            kind: .carPlay, enableCarPlay: true
        ))
    }

    @Test func `should fall back to the phone without enabling CarPlay when the display query is unknown`() {
        #expect(StreamDisplayPlan.from(query: "tv") == StreamDisplayPlan(
            kind: .phone, enableCarPlay: false
        ))
    }

    @Test func `should force the phone screen for 3D routes`() {
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

    @Test func `should bind the phone screen and input without touching external displays`() throws {
        let sim = MockSimulator()
        let screen = MockScreen()
        let input = InputMocks()
        given(sim).screen().willReturn(screen)
        given(sim).input().willReturn(input)

        let bound = try StreamDisplayPlan(kind: .phone, enableCarPlay: false).bind(to: sim)

        #expect(bound.screen as? MockScreen === screen)
        #expect(bound.input as? InputMocks === input)
        verify(sim).externalDisplays().called(0)
        verify(sim).displays().called(0)
    }

    /// A foldable's page brings the other panel in while the hinge is
    /// still turning — before the runtime has swapped — so the stream
    /// it opens must be pinned to that panel rather than follow the
    /// hinge. Pinned, the phone plane comes from `displays().panel(_:)`.
    @Test func `should bind the phone screen and input to the pinned panel`() throws {
        let sim = MockSimulator()
        let displays = MockDisplays()
        let display = MockDisplay()
        let screen = MockScreen()
        let input = InputMocks()
        given(sim).displays().willReturn(displays)
        given(displays).panel(.value(.secondary)).willReturn(display)
        given(display).screen().willReturn(screen)
        given(display).input().willReturn(input)

        let plan = StreamDisplayPlan.from(query: nil, panel: "secondary")
        #expect(plan.panel == .secondary)
        let bound = try plan.bind(to: sim)

        #expect(bound.screen as? MockScreen === screen)
        #expect(bound.input as? InputMocks === input)
        verify(sim).screen().called(0)
    }

    @Test func `should leave the panel to the hinge when the panel query is absent, unknown or on CarPlay`() {
        #expect(StreamDisplayPlan.from(query: nil, panel: nil).panel == nil)
        #expect(StreamDisplayPlan.from(query: nil, panel: "inner").panel == nil)
        #expect(StreamDisplayPlan.from(query: "phone", panel: "primary").panel == .primary)
        // A pin only makes sense for the phone plane.
        #expect(StreamDisplayPlan.from(query: "carplay", panel: "secondary").panel == nil)
    }

    @Test func `should enable the CarPlay panel then bind its screen and input`() throws {
        let sim = MockSimulator()
        let external = MockExternalDisplays()
        let displays = MockDisplays()
        let carPlay = MockDisplay()
        let screen = MockScreen()
        let input = InputMocks()
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
        #expect(bound.input as? InputMocks === input)
        verify(external).enableCarPlay().called(1)
        verify(carPlay).resolve().called(1)
        verify(sim).screen().called(0)
        verify(sim).input().called(0)
    }

    @Test func `should fail closed when the CarPlay screen cannot be found`() {
        let sim = MockSimulator()
        let external = MockExternalDisplays()
        let displays = MockDisplays()
        let carPlay = MockDisplay()
        given(sim).externalDisplays().willReturn(external)
        given(external).enableCarPlay().willReturn(())
        given(sim).displays().willReturn(displays)
        given(displays).carPlay.willReturn(carPlay)
        given(carPlay).resolve().willThrow(FramebufferSelectionError.noMatchingFramebuffer(.carPlay))

        #expect(throws: FramebufferSelectionError.noMatchingFramebuffer(.carPlay)) {
            try StreamDisplayPlan(kind: .carPlay, enableCarPlay: true).bind(to: sim)
        }
        verify(carPlay).screen().called(0)
        verify(carPlay).input().called(0)
    }

    @Test func `should surface the failure when the CarPlay panel cannot be enabled`() {
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

    @Test func `should stream the phone without enabling CarPlay when --display is absent`() throws {
        #expect(try StreamDisplayPlan.from(cliFlag: nil) == StreamDisplayPlan(
            kind: .phone, enableCarPlay: false
        ))
    }

    @Test func `should stream the phone without enabling CarPlay when --display is phone`() throws {
        #expect(try StreamDisplayPlan.from(cliFlag: "phone") == StreamDisplayPlan(
            kind: .phone, enableCarPlay: false
        ))
    }

    @Test func `should stream CarPlay and enable its panel when --display is carplay`() throws {
        #expect(try StreamDisplayPlan.from(cliFlag: "carplay") == StreamDisplayPlan(
            kind: .carPlay, enableCarPlay: true
        ))
        #expect(try StreamDisplayPlan.from(cliFlag: "CARPLAY") == StreamDisplayPlan(
            kind: .carPlay, enableCarPlay: true
        ))
    }

    @Test func `should reject an unknown --display value rather than fall back to the phone`() {
        #expect(throws: DisplayFlagError.unknown("carply")) {
            try StreamDisplayPlan.from(cliFlag: "carply")
        }
    }

    /// `--display ""` is the shape an unset variable takes —
    /// `--display "$PLANE"` with nothing in `$PLANE`. Reading it as phone
    /// is the silent-wrong-plane the strict parser exists to prevent, and
    /// it is the worst kind of silent: a CarPlay run against the phone
    /// passes, for the wrong reason. Omitting the flag entirely is how you
    /// ask for the default; passing it empty is a broken command line.
    @Test func `should reject an empty --display value rather than read it as phone`() {
        #expect(throws: DisplayFlagError.unknown("")) {
            try StreamDisplayPlan.from(cliFlag: "")
        }
    }

    /// The forgiving half of the pair is unchanged: a URL is not a command
    /// line, and `?display=` there still means phone.
    @Test func `should still read an empty display query as phone`() {
        #expect(StreamDisplayPlan.from(query: "") == StreamDisplayPlan(
            kind: .phone, enableCarPlay: false
        ))
    }

    /// The rejection is what the operator actually reads, so the wording is
    /// part of the contract: it has to name the planes that would have
    /// worked and echo the token that didn't, or a typo costs a round trip
    /// to the docs to spot.
    @Test func `should name both displays and echo what was typed when --display is rejected`() {
        #expect(
            DisplayFlagError.unknown("carply").message
            == #"--display must be one of: phone, carplay (got "carply")"#
        )
    }

    @Test func `should echo a blank --display value verbatim when it is rejected`() {
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
