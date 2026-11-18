import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// A phone's touchscreen through CoreDevice's Universal HID, with the
/// capability mocked: what reaches the phone, and when CoreDevice is asked
/// to open the touch service again.
@Suite("CoreDeviceDigitizer")
struct CoreDeviceDigitizerTests {
    private let phone = UUID(uuidString: "30546CC9-90DC-5F06-87D3-42D2C2E913D1")!
    private let finger = [Contact(x: 0.5, y: 0.5)]

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSinceReferenceDate: 0)
    }

    private struct Refused: Error {}

    /// Universal HID that can build reports, opens with `opening`, and takes
    /// every report sent.
    private func hid(
        builds: Bool = true,
        opening: @escaping @Sendable () throws -> OpenedCapability? = { OpenedCapability() }
    ) -> MockUniversalHID {
        let hid = MockUniversalHID()
        given(hid).buildsTouchReports.willReturn(builds)
        given(hid).open(on: .any).willProduce { _ in try opening() }
        given(hid).send(.any, to: .any, through: .any).willReturn(true)
        return hid
    }

    @Test func `should land the fingers on the phone's main touchscreen`() {
        let hid = hid()
        let digitizer = CoreDeviceDigitizer(identifier: phone, hid: hid)

        #expect(digitizer.report(finger, touching: true, edge: .bottom))

        verify(hid).send(.value(DigitizerReport(contacts: finger, touching: true, edge: .bottom)),
                         to: .value(0x101), through: .any).called(1)
    }

    @Test func `should send nothing when no finger or more than two are on the glass`() {
        let hid = hid()
        let digitizer = CoreDeviceDigitizer(identifier: phone, hid: hid)

        #expect(!digitizer.report([], touching: true, edge: nil))
        #expect(!digitizer.report(finger + finger + finger, touching: true, edge: nil))

        verify(hid).open(on: .any).called(0)
    }

    @Test func `should open the phone's touch service once and keep it`() {
        let hid = hid()
        let digitizer = CoreDeviceDigitizer(identifier: phone, hid: hid)

        _ = digitizer.report(finger, touching: true, edge: nil)
        _ = digitizer.report(finger, touching: false, edge: nil)

        verify(hid).open(on: .value(phone)).called(1)
        verify(hid).send(.any, to: .any, through: .any).called(2)
    }

    @Test func `should not ask CoreDevice again within ten seconds of failing to open the touch service`() {
        let clock = Clock()
        let hid = hid(opening: { throw Refused() })
        let digitizer = CoreDeviceDigitizer(identifier: phone, hid: hid, now: { clock.now })

        #expect(!digitizer.report(finger, touching: true, edge: nil))
        clock.now += 9
        #expect(!digitizer.report(finger, touching: true, edge: nil))

        verify(hid).open(on: .any).called(1)
        verify(hid).send(.any, to: .any, through: .any).called(0)
    }

    @Test func `should ask CoreDevice again once ten seconds have passed since it failed`() {
        let clock = Clock()
        let hid = hid(opening: { throw Refused() })
        let digitizer = CoreDeviceDigitizer(identifier: phone, hid: hid, now: { clock.now })

        _ = digitizer.report(finger, touching: true, edge: nil)
        clock.now += 10
        _ = digitizer.report(finger, touching: true, edge: nil)

        verify(hid).open(on: .any).called(2)
    }

    @Test func `should wait out ten seconds too when CoreDevice doesn't list the phone`() {
        let hid = hid(opening: { nil })
        let digitizer = CoreDeviceDigitizer(identifier: phone, hid: hid)

        #expect(!digitizer.report(finger, touching: true, edge: nil))
        #expect(!digitizer.report(finger, touching: true, edge: nil))

        verify(hid).open(on: .any).called(1)
    }

    @Test func `should open nothing when this Xcode's Universal HID can't build a touch report`() {
        let hid = hid(builds: false)
        let digitizer = CoreDeviceDigitizer(identifier: phone, hid: hid)

        #expect(!digitizer.report(finger, touching: true, edge: nil))
        #expect(!digitizer.report(finger, touching: true, edge: nil))

        verify(hid).open(on: .any).called(0)
        verify(hid).buildsTouchReports.called(2)
    }

    @Test func `should open the touch service again after a failure once it can`() {
        let clock = Clock()
        let attempts = Attempts()
        let hid = hid(opening: { attempts.next() == 1 ? nil : OpenedCapability() })
        let digitizer = CoreDeviceDigitizer(identifier: phone, hid: hid, now: { clock.now })

        #expect(!digitizer.report(finger, touching: true, edge: nil))
        clock.now += 10
        #expect(digitizer.report(finger, touching: true, edge: nil))
        #expect(digitizer.report(finger, touching: false, edge: nil))

        verify(hid).open(on: .any).called(2)
    }

    private final class Attempts: @unchecked Sendable {
        private var count = 0
        func next() -> Int { count += 1; return count }
    }
}
