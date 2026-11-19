import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// Pure-value coverage for `Bearing` — the compass direction a
/// `LocationWalk` travels. Unlike `Coordinate`'s latitude/longitude, a
/// bearing has no invalid value: the compass is a circle, so every input
/// normalises onto [0, 360) rather than failing. The joystick hands us
/// `atan2` output in any range (negative, past a full turn), so the
/// normalisation is the type's whole job.
@Suite("Bearing")
struct BearingTests {

    @Test func `should keep a bearing that is already on the compass circle`() {
        #expect(Bearing(degrees: 90).degrees == 90)
        #expect(Bearing(degrees: 0).degrees == 0)
        #expect(Bearing(degrees: 359.9).degrees == 359.9)
    }

    @Test func `should wrap a negative bearing onto the compass circle`() {
        #expect(Bearing(degrees: -90).degrees == 270)
        #expect(Bearing(degrees: -1).degrees == 359)
    }

    @Test func `should wrap a bearing past a full turn back onto the compass circle`() {
        #expect(Bearing(degrees: 450).degrees == 90)
        #expect(Bearing(degrees: 720).degrees == 0)
    }

    @Test func `should read a full turn as north`() {
        #expect(Bearing(degrees: 360).degrees == 0)
    }

    @Test func `should express the bearing in radians for the projection maths`() {
        #expect(abs(Bearing(degrees: 180).radians - Double.pi) < 1e-12)
        #expect(abs(Bearing(degrees: 90).radians - Double.pi / 2) < 1e-12)
    }

    @Test func `should name the nearest cardinal point for a compass readout`() {
        #expect(Bearing(degrees: 0).cardinal == "N")
        #expect(Bearing(degrees: 90).cardinal == "E")
        #expect(Bearing(degrees: 180).cardinal == "S")
        #expect(Bearing(degrees: 270).cardinal == "W")
        #expect(Bearing(degrees: 45).cardinal == "NE")
        // Nearest-point rounding, not truncation: 350° is N, not NW.
        #expect(Bearing(degrees: 350).cardinal == "N")
    }
}
