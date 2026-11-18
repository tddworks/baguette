import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// A fold or rotation is delivered, rejected, or — when the guest helper
/// timed out and was stopped — unconfirmed. Every command and route takes
/// the outcome of a failure from here.
@Suite("PoseDelivery")
struct PoseDeliveryTests {
    @Test func `should leave a pose change unconfirmed only when the helper timed out`() {
        #expect(PoseDelivery(failure: HingeError.toolTimedOut) == .unconfirmed)
        #expect(PoseDelivery(failure: HingeError.toolStartedLate) == .rejected)
        #expect(PoseDelivery(failure: HingeError.toolFailed(status: 1)) == .rejected)
        #expect(PoseDelivery(failure: HingeError.toolMissing) == .rejected)
        #expect(PoseDelivery(failure: CocoaError(.fileNoSuchFile)) == .rejected)
    }

    @Test func `should end a command with each outcome's documented exit status`() {
        #expect(PoseDelivery.delivered.exitStatus == 0)
        #expect(PoseDelivery.rejected.exitStatus == 1)
        #expect(PoseDelivery.unconfirmed.exitStatus == 3)
    }
}
