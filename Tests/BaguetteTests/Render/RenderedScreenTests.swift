import Foundation
import IOSurface
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("RenderedScreen")
struct RenderedScreenTests {
    @Test func `should render source surfaces before delivering them to a codec`() throws {
        let source = MockScreen()
        let scene = MockDeviceScene()
        let input = try #require(Self.surface(width: 2, height: 2))
        let rendered = try #require(Self.surface(width: 4, height: 3))
        var sourceDelivery: (@Sendable (IOSurface) -> Void)?
        let delivered = LockedSurface()
        given(source).start(onFrame: .any).willProduce { sourceDelivery = $0 }
        given(source).stop().willReturn()
        given(scene).render(screen: .value(input)).willReturn(rendered)
        let screen = RenderedScreen(source: source, scene: scene)

        try screen.start { delivered.set($0) }
        sourceDelivery?(input)

        #expect(Self.waitUntil { delivered.value != nil })
        #expect(delivered.value.map(IOSurfaceGetWidth) == 4)
        #expect(delivered.value.map(IOSurfaceGetHeight) == 3)
        screen.stop()
        verify(scene).render(screen: .value(input)).called(1)
        verify(source).stop().called(1)
    }

    @Test func `should never block source delivery on slow rendering`() throws {
        let source = MockScreen()
        let scene = MockDeviceScene()
        let input = try #require(Self.surface(width: 2, height: 2))
        let rendered = try #require(Self.surface(width: 4, height: 3))
        let release = DispatchSemaphore(value: 0)
        var sourceDelivery: (@Sendable (IOSurface) -> Void)?
        given(source).start(onFrame: .any).willProduce { sourceDelivery = $0 }
        given(scene).render(screen: .any).willProduce { _ in
            _ = release.wait(timeout: .now() + 0.15)
            return rendered
        }
        let screen = RenderedScreen(source: source, scene: scene)
        try screen.start { _ in }

        let started = ContinuousClock.now
        sourceDelivery?(input)
        let elapsed = started.duration(to: .now)
        release.signal()

        #expect(elapsed < .milliseconds(50))
    }

    @Test func `should rerender the latest simulator surface on refresh after the camera moves`() throws {
        let source = MockScreen()
        let scene = MockDeviceScene()
        let input = try #require(Self.surface(width: 2, height: 2))
        let rendered = try #require(Self.surface(width: 4, height: 3))
        var sourceDelivery: (@Sendable (IOSurface) -> Void)?
        let renderCount = LockedCount()
        given(source).start(onFrame: .any).willProduce { sourceDelivery = $0 }
        given(scene).render(screen: .any).willProduce { _ in
            renderCount.increment()
            return rendered
        }
        let screen = RenderedScreen(source: source, scene: scene)
        try screen.start { _ in }
        sourceDelivery?(input)
        #expect(Self.waitUntil { renderCount.value == 1 })

        screen.refresh()

        #expect(Self.waitUntil { renderCount.value == 2 })
    }
}

private final class LockedSurface: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: IOSurface?
    var value: IOSurface? { lock.withLock { storage } }
    func set(_ surface: IOSurface) { lock.withLock { storage = surface } }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

extension RenderedScreenTests {
    static func surface(width: Int, height: Int) -> IOSurface? {
        IOSurfaceCreate([
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: width * 4,
            kIOSurfaceAllocSize: width * height * 4,
            kIOSurfacePixelFormat: UInt32(0x42475241),
        ] as CFDictionary)
    }

    static func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }
}
