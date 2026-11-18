import Testing
import Foundation
@testable import Baguette
@testable import BaguetteDevice

/// The angle a foldable's book is shown at. A sweep baguette plays is
/// shown as it is commanded, at 60 Hz, however late the guest's readings
/// come back; then the book stands at the target until the readings get
/// there, and follows them again.
@Suite("PosedHinge")
struct PosedHingeTests {
    private let open = HingeSweep(from: 180, to: 130, duration: 0.8)

    private func standing(after sweep: HingeSweep, delivered: PoseDelivery = .delivered) -> PosedHinge {
        var posed = PosedHinge(reading: sweep.from)
        posed.began(sweep, at: 10)
        posed.ended(delivered)
        return posed
    }

    @Test func `should follow the hinge's reading when baguette plays no sweep`() {
        var posed = PosedHinge(reading: 130)
        #expect(posed.degrees(at: 0) == 130)
        posed.heard(HingeAngle(degrees: 42))
        #expect(posed.degrees(at: 0) == 42)
    }

    @Test func `should show the sweep it plays rather than the readings while it plays`() {
        var posed = PosedHinge(reading: 180)
        posed.began(open, at: 10)
        #expect(posed.degrees(at: 10) == open.degrees(after: 0))
        posed.heard(HingeAngle(degrees: 177))
        #expect(posed.degrees(at: 10.4) == open.degrees(after: 0.4))
        #expect(posed.degrees(at: 11) == 130)
    }

    @Test func `should stand at the target until a reading lands there, then follow the readings`() {
        var posed = standing(after: open)
        posed.heard(HingeAngle(degrees: 150))
        posed.heard(HingeAngle(degrees: 140))
        #expect(posed.degrees(at: 12) == 130)
        posed.heard(HingeAngle(degrees: 130.2))
        #expect(posed.degrees(at: 12) == 130.2)
        posed.heard(HingeAngle(degrees: 140))
        #expect(posed.degrees(at: 12) == 140)
    }

    @Test func `should follow a fold made elsewhere while it stands at the target`() {
        var beyond = standing(after: open)
        beyond.heard(HingeAngle(degrees: 100))
        #expect(beyond.degrees(at: 12) == 100)

        var back = standing(after: open)
        back.heard(HingeAngle(degrees: 150))
        back.heard(HingeAngle(degrees: 155))
        #expect(back.degrees(at: 12) == 155)
    }

    @Test func `should follow the reading at once when the sweep was not delivered`() {
        for delivery in [PoseDelivery.rejected, .unconfirmed] {
            var posed = PosedHinge(reading: 180)
            posed.began(open, at: 10)
            posed.heard(HingeAngle(degrees: 170))
            posed.ended(delivery)
            #expect(posed.degrees(at: 12) == 170)
        }
    }

    @Test func `should play the next sweep from where it was asked to start`() {
        var posed = standing(after: open)
        let shut = HingeSweep(from: 150, to: 0, duration: 0.8)
        posed.began(shut, at: 20)
        #expect(posed.degrees(at: 20) == shut.degrees(after: 0))
    }

    @Test func `should keep moving only until the sweep's last sample`() {
        var posed = PosedHinge(reading: 180)
        #expect(!posed.isMoving(at: 0))
        posed.began(open, at: 10)
        #expect(posed.isMoving(at: 10))
        #expect(posed.isMoving(at: 10 + open.settlesAfter - 0.01))
        #expect(!posed.isMoving(at: 10 + open.settlesAfter))
        posed.began(open, at: 20)
        posed.ended(.delivered)
        #expect(!posed.isMoving(at: 20))
    }
}
