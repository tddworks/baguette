import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// What one Universal HID digitizer report says: each finger's number,
/// place and contact, and — for a swipe in from an edge — which way it moves.
@Suite("DigitizerReport")
struct DigitizerReportTests {
    private let one = Contact(x: 0.25, y: 0.5)
    private let two = Contact(x: 0.75, y: 0.125)

    @Test func `should number each finger from one, touching and in range while down`() {
        let report = DigitizerReport(contacts: [one, two], touching: true, edge: nil)

        #expect(report.fingers == [
            .init(index: 1, x: 0.25, y: 0.5, touching: true, swipe: nil),
            .init(index: 2, x: 0.75, y: 0.125, touching: true, swipe: nil),
        ])
    }

    @Test func `should lift every finger out of range when the touch ends`() {
        let report = DigitizerReport(contacts: [one], touching: false, edge: nil)

        #expect(report.fingers == [.init(index: 1, x: 0.25, y: 0.5, touching: false, swipe: nil)])
    }

    @Test func `should mark a swipe in from an edge as moving inward from it on every finger`() {
        let swipes = [DeviceEdge.left, .top, .bottom, .right].map {
            DigitizerReport(contacts: [one, two], touching: false, edge: $0).fingers.map(\.swipe)
        }

        #expect(swipes == [[.right, .right], [.down, .down], [.up, .up], [.left, .left]])
    }
}
