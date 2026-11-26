import Foundation
import Mockable
import Testing
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// Which panel a foldable lights is SpringBoard's call, and Core Device
/// reports it: the pose provider holds a panel through a slow fold (it
/// kept the cover lit at 130° after a fold in small steps, measured on an
/// iPhone Duo, iOS 27.1) and an app may light the cover while open. The
/// angle only stands in when Core Device can't say.
@Suite("SharedHinge — the panel Core Device lights")
struct SharedHingePresentingPanelTests {
    final class Asks: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: IntegratedPanel?
        private(set) var count = 0
        init(_ answer: IntegratedPanel?) { self.answer = answer }
        func ask() -> IntegratedPanel? {
            lock.withLock { count += 1; return answer }
        }
        func answer(_ panel: IntegratedPanel?) { lock.withLock { answer = panel } }
        var asked: Int { lock.withLock { count } }
    }

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 0)
    }

    private func hinge(at degrees: Double) -> MockHinge {
        let inner = MockHinge()
        given(inner).angle().willReturn(HingeAngle(degrees: degrees))
        return inner
    }

    @Test func `should light the panel Core Device says the device presents on, whatever the angle`() {
        let asks = Asks(.primary)
        let shared = SharedHinge(inner: hinge(at: 130), presenting: asks.ask)

        #expect(shared.presentingPanel() == .primary)
        #expect(shared.litPanel == .primary)
    }

    @Test func `should fall back to the angle when Core Device can't say`() {
        let shared = SharedHinge(inner: hinge(at: 130), presenting: Asks(nil).ask)

        #expect(shared.presentingPanel() == nil)
        #expect(shared.litPanel == .secondary)
    }

    @Test func `should ask nothing of Core Device for a device it was given no way to ask about`() {
        let shared = SharedHinge(inner: hinge(at: 130))

        #expect(shared.presentingPanel() == nil)
        #expect(shared.litPanel == .secondary)
    }

    @Test func `should ask Core Device again only once its answer has stood its lifetime, while nobody watches`() {
        let asks = Asks(.primary)
        let clock = Clock()
        let shared = SharedHinge(inner: hinge(at: 130), now: { clock.now }, presenting: asks.ask)

        _ = shared.presentingPanel()
        clock.now += SharedHinge.presentingLifetime / 2
        _ = shared.presentingPanel()
        #expect(asks.asked == 1)

        clock.now += SharedHinge.presentingLifetime
        _ = shared.presentingPanel()
        #expect(asks.asked == 2)
    }

    @Test func `should follow the panel Core Device lights once the hinge settles, while it is watched`() async throws {
        let inner = hinge(at: 100)
        let innerWatch = MockHingeWatch()
        given(innerWatch).cancel().willReturn()
        final class Sample: @unchecked Sendable { var deliver: (@Sendable (HingeAngle) -> Void)? }
        let sample = Sample()
        given(inner).watch(onAngle: .any).willProduce { deliver in
            sample.deliver = deliver
            return innerWatch
        }
        let asks = Asks(.primary)
        let shared = SharedHinge(inner: inner, presenting: asks.ask, settleDelays: [0.01], pollInterval: 60)
        let watch = shared.watch { _ in }
        defer { watch.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(shared.presentingPanel() == .primary)

        asks.answer(.secondary)
        sample.deliver?(HingeAngle(degrees: 180))
        try await Task.sleep(for: .milliseconds(200))

        #expect(shared.presentingPanel() == .secondary)
    }
}
