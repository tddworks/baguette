import CoreVideo
import Foundation
import IOSurface
import Mockable
import Testing
@testable import BaguetteDevice

/// One live screen, watched by many: a phone on a cable streams its screen to
/// one receiver, so every viewer of it has to share that one stream.
@Suite("SharedScreen")
struct SharedScreenTests {

    /// A device's live screen: how many times it was started and stopped, and
    /// a way to show a picture on it while it runs.
    final class LiveScreen: @unchecked Sendable {
        let screen = MockScreen()
        private let lock = NSLock()
        private var onFrame: (@Sendable (IOSurface) -> Void)?
        private(set) var starts = 0
        private(set) var stops = 0

        init(failing: Bool = false) {
            if failing {
                given(screen).start(onFrame: .any).willThrow(StartFailed())
            } else {
                given(screen).start(onFrame: .any).willProduce { [self] onFrame in
                    lock.withLock { starts += 1; self.onFrame = onFrame }
                }
            }
            given(screen).stop().willProduce { [self] in lock.withLock { stops += 1; onFrame = nil } }
        }

        func show(_ surface: IOSurface) {
            lock.withLock { onFrame }?(surface)
        }
    }

    struct StartFailed: Error {}

    /// Counts the times the device's screen was made.
    final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
    }

    /// What a viewer was shown.
    final class Viewer: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [IOSurface] = []
        var shown: [IOSurface] { lock.withLock { seen } }
        lazy var onFrame: @Sendable (IOSurface) -> Void = { [self] surface in lock.withLock { seen.append(surface) } }
    }

    static func picture() -> IOSurface {
        IOSurface(properties: [
            .width: 4, .height: 4, .bytesPerElement: 4, .bytesPerRow: 16,
            .pixelFormat: kCVPixelFormatType_32BGRA, .allocSize: 64,
        ])!
    }

    @Test func `should start the device's screen once however many viewers watch it`() throws {
        let live = LiveScreen()
        let shared = SharedScreen { live.screen }

        try shared.view().start(onFrame: Viewer().onFrame)
        try shared.view().start(onFrame: Viewer().onFrame)

        #expect(live.starts == 1)
    }

    @Test func `should show every viewer each picture`() throws {
        let live = LiveScreen()
        let shared = SharedScreen { live.screen }
        let (first, second) = (Viewer(), Viewer())
        try shared.view().start(onFrame: first.onFrame)
        try shared.view().start(onFrame: second.onFrame)

        let picture = Self.picture()
        live.show(picture)

        #expect(first.shown == [picture])
        #expect(second.shown == [picture])
    }

    @Test func `should keep showing a viewer pictures when another viewer leaves`() throws {
        let live = LiveScreen()
        let shared = SharedScreen { live.screen }
        let staying = Viewer()
        try shared.view().start(onFrame: staying.onFrame)
        let leaving = shared.view()
        try leaving.start(onFrame: Viewer().onFrame)

        leaving.stop()
        let picture = Self.picture()
        live.show(picture)

        #expect(live.stops == 0)
        #expect(staying.shown == [picture])
    }

    @Test func `should stop the device's screen when the last viewer leaves`() throws {
        let live = LiveScreen()
        let shared = SharedScreen { live.screen }
        let (first, second) = (shared.view(), shared.view())
        try first.start(onFrame: Viewer().onFrame)
        try second.start(onFrame: Viewer().onFrame)

        first.stop()
        second.stop()

        #expect(live.stops == 1)
    }

    @Test func `should start the device's screen again for a viewer who comes after the last one left`() throws {
        let live = LiveScreen()
        let shared = SharedScreen { live.screen }
        let first = shared.view()
        try first.start(onFrame: Viewer().onFrame)
        first.stop()

        try shared.view().start(onFrame: Viewer().onFrame)

        #expect(live.starts == 2)
    }

    @Test func `should show a viewer who joins late the newest picture at once`() throws {
        let live = LiveScreen()
        let shared = SharedScreen { live.screen }
        try shared.view().start(onFrame: Viewer().onFrame)
        let picture = Self.picture()
        live.show(picture)

        let late = Viewer()
        try shared.view().start(onFrame: late.onFrame)

        #expect(late.shown == [picture])
    }

    @Test func `should tell a viewer why when the device's screen can't start`() {
        let shared = SharedScreen { LiveScreen(failing: true).screen }

        #expect(throws: StartFailed.self) { try shared.view().start(onFrame: Viewer().onFrame) }
    }

    @Test func `should try the device's screen again for the next viewer when it couldn't start`() throws {
        let attempts = Attempts()
        let working = LiveScreen()
        let shared = SharedScreen {
            attempts.next() == 1 ? LiveScreen(failing: true).screen : working.screen
        }
        #expect(throws: StartFailed.self) { try shared.view().start(onFrame: Viewer().onFrame) }

        try shared.view().start(onFrame: Viewer().onFrame)

        #expect(working.starts == 1)
    }

    @Test func `should leave the device's screen running when a viewer that never started stops`() throws {
        let live = LiveScreen()
        let shared = SharedScreen { live.screen }
        try shared.view().start(onFrame: Viewer().onFrame)

        shared.view().stop()

        #expect(live.stops == 0)
    }
}

/// Each device's one shared screen, for a family whose devices are made afresh on every lookup.
@Suite("SharedScreens")
struct SharedScreensTests {

    @Test func `should share one screen among the viewers of the same device`() throws {
        let live = SharedScreenTests.LiveScreen()
        let screens = SharedScreens()

        try screens.view(of: DeviceID("PHONE")) { live.screen }.start(onFrame: { _ in })
        try screens.view(of: DeviceID("PHONE")) { live.screen }.start(onFrame: { _ in })

        #expect(live.starts == 1)
    }

    @Test func `should give each device a screen of its own`() throws {
        let (first, second) = (SharedScreenTests.LiveScreen(), SharedScreenTests.LiveScreen())
        let screens = SharedScreens()

        try screens.view(of: DeviceID("ONE")) { first.screen }.start(onFrame: { _ in })
        try screens.view(of: DeviceID("TWO")) { second.screen }.start(onFrame: { _ in })

        #expect(first.starts == 1)
        #expect(second.starts == 1)
    }
}

