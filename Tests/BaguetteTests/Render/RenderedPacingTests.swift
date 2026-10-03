import Foundation
import IOSurface
import Mockable
import Testing

@testable import Baguette

@Suite("RenderedPacing")
struct RenderedPacingTests {
    @Test func `source bursts and camera refresh share one render limit and flush the last frame`() throws {
        let source = MockScreen()
        let scene = MockDeviceScene()
        var receive: (@Sendable (IOSurface) -> Void)?
        let samples = RenderSamples()
        given(source).start(onFrame: .any).willProduce { receive = $0 }
        given(source).stop().willReturn()
        given(scene).renderFrame(screen: .any).willProduce { surface in samples.render(surface) }
        let screen = RenderedScreen(source: source, scene: scene, fps: 20)
        try screen.startFrames { samples.deliver($0) }
        defer { screen.stop() }
        for index in 2...21 {
            receive?(try #require(RenderedScreenTests.surface(width: index, height: 2)))
            screen.refresh()
            Thread.sleep(forTimeInterval: 1.0 / 120)
        }
        #expect(RenderedScreenTests.waitUntil { samples.lastWidth == 21 })
        let beforeRefresh = samples.frames.count
        screen.refresh()
        #expect(RenderedScreenTests.waitUntil { samples.frames.count > beforeRefresh })
        samples.expectPaced()
        let last = try #require(samples.frames.last).get()
        #expect(IOSurfaceGetWidth(last.surface) == 21)
        #expect(last.placement?.sourcePixelSize.width == 21)
    }

    @Test func `both foldable panels and pose refresh share the same render limit`() throws {
        let inner = MockScreen()
        let cover = MockScreen()
        let hinge = MockHinge()
        let watch = MockHingeWatch()
        let scene = MockDeviceScene()
        var receiveInner: (@Sendable (IOSurface) -> Void)?
        var receiveCover: (@Sendable (IOSurface) -> Void)?
        let samples = RenderSamples()
        given(inner).start(onFrame: .any).willProduce { receiveInner = $0 }
        given(cover).start(onFrame: .any).willProduce { receiveCover = $0 }
        given(inner).stop().willReturn()
        given(cover).stop().willReturn()
        given(hinge).angle().willReturn(HingeAngle(degrees: 180))
        given(hinge).watch(onAngle: .any).willReturn(watch)
        given(watch).cancel().willReturn()
        given(scene).update(hingeDegrees: .any).willReturn()
        given(scene).renderFrame(screens: .any).willProduce { screens in
            samples.render(try #require(screens.unfolded ?? screens.cover))
        }
        let screen = RenderedFoldable(unfolded: inner, cover: cover, hinge: hinge, scene: scene, fps: 20)
        try screen.startFrames { samples.deliver($0) }
        defer { screen.stop() }
        for index in 2...21 {
            let surface = try #require(RenderedScreenTests.surface(width: index, height: 2))
            receiveInner?(surface)
            receiveCover?(surface)
            screen.refresh()
            Thread.sleep(forTimeInterval: 1.0 / 120)
        }
        #expect(RenderedScreenTests.waitUntil { samples.lastWidth == 21 })
        samples.expectPaced()
        let last = try #require(samples.frames.last).get()
        #expect(last.placement?.sourcePixelSize.width == 21)
    }

    @Test func `stop cancels pending renders without waiting on a main thread render`() throws {
        let source = MockScreen()
        let scene = MockDeviceScene()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        var receive: (@Sendable (IOSurface) -> Void)?
        let samples = RenderSamples()
        given(source).start(onFrame: .any).willProduce { receive = $0 }
        given(source).stop().willReturn()
        given(scene).renderFrame(screen: .any).willProduce { surface in
            started.signal()
            _ = release.wait(timeout: .now() + 2)
            defer { finished.signal() }
            return samples.render(surface)
        }
        let screen = RenderedScreen(source: source, scene: scene, fps: 20)
        try screen.startFrames { samples.deliver($0) }
        let surface = try #require(RenderedScreenTests.surface(width: 2, height: 2))
        receive?(surface)
        #expect(started.wait(timeout: .now() + 1) == .success)
        receive?(surface)
        let start = ContinuousClock.now
        screen.stop()
        let elapsed = start.duration(to: .now)
        release.signal()
        #expect(elapsed < .milliseconds(200))
        #expect(finished.wait(timeout: .now() + 1) == .success)
        Thread.sleep(forTimeInterval: 0.1)
        #expect(samples.frames.isEmpty)
        #expect(samples.renderTimes.count == 1)
    }
}

private final class RenderSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Double] = []
    private var received: [Result<DeviceFrame, any Error>] = []
    var frames: [Result<DeviceFrame, any Error>] { lock.withLock { received } }
    var renderTimes: [Double] { lock.withLock { times } }
    var lastWidth: Int? { try? frames.last?.get().placement?.sourcePixelSize.width }

    func render(_ surface: IOSurface) -> DeviceFrame {
        lock.withLock { times.append(Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000) }
        return DeviceFrame(surface: surface, placement: DeviceFrameTests.placement(width: IOSurfaceGetWidth(surface)))
    }

    func deliver(_ frame: Result<DeviceFrame, any Error>) { lock.withLock { received.append(frame) } }

    func expectPaced() {
        let times = renderTimes
        #expect(times.count >= 2)
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 >= 0.048 })
    }
}
