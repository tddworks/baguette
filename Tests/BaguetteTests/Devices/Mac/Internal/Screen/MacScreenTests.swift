import Foundation
import IOSurface
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// A Mac display's screen, through ScreenCaptureKit's feed: each complete
/// picture handed on as a surface, an unchanged one never, and a feed that
/// ends started again while the screen is.
@Suite("MacScreen")
struct MacScreenTests {
    let display = MacDisplayInfo(
        id: 2, uuid: "D-UUID", name: "Studio Display", isMain: false,
        bounds: Rect(origin: Point(x: 1512, y: 0), size: Size(width: 2560, height: 1440)))

    /// ScreenCaptureKit's feed, played by the test: it remembers how it was
    /// started, and the test hands pictures and ends through it.
    final class Feed: @unchecked Sendable {
        let feed = MockDisplayFeed()
        private let lock = NSLock()
        private var _starts: [(display: UInt32, size: Size)] = []
        private var onPicture: (@Sendable (FeedPicture) -> Void)?
        private var onEnd: (@Sendable () -> Void)?
        var starts: [(display: UInt32, size: Size)] { lock.withLock { _starts } }

        /// `sees`: the display as ScreenCaptureKit reports it when the feed
        /// starts — its points and pixels a point.
        init(refusal: Error? = nil, sees: (points: Size, scale: Double) = (Size(width: 2560, height: 1440), 2)) {
            given(feed).start(display: .any, sizing: .any, onPicture: .any, onEnd: .any)
                .willProduce { [self] display, sizing, onPicture, onEnd in
                    if let refusal { throw refusal }
                    lock.withLock {
                        _starts.append((display, sizing(sees.points, sees.scale)))
                        self.onPicture = onPicture
                        self.onEnd = onEnd
                    }
                }
            given(feed).stop().willReturn()
        }

        func picture(_ picture: FeedPicture) { lock.withLock { onPicture }?(picture) }
        func end() { lock.withLock { onEnd }?() }
    }

    final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func add(_: IOSurface) { lock.withLock { _count += 1 } }
    }

    func screen(on feed: Feed) -> MacScreen {
        MacScreen(display: display, feed: feed.feed, pause: { _ in })
    }

    @Test func `should capture a display at its pixels as it is when the feed starts`() throws {
        let feed = Feed(sees: (Size(width: 603, height: 1311), 2))
        try screen(on: feed).start { _ in }
        #expect(feed.starts.map(\.display) == [2])
        #expect(feed.starts.map(\.size) == [Size(width: 1206, height: 2622)])
    }

    @Test func `should capture a display baguette made at the pixels it made it with, whatever ScreenCaptureKit says`() throws {
        // A long-running server can read a just-made display as 1×: here 589 × 988 points at 1.
        let feed = Feed(sees: (Size(width: 589, height: 988), 1))
        let made = MacScreen(display: display, feed: feed.feed, madePixels: Size(width: 1178, height: 1976), pause: { _ in })
        try made.start { _ in }
        #expect(feed.starts.map(\.size) == [Size(width: 1178, height: 1976)])
    }

    @Test func `should capture a 5K display no larger than the encoder takes`() throws {
        let feed = Feed(sees: (Size(width: 2560, height: 1440), 2))
        try screen(on: feed).start { _ in }
        #expect(feed.starts.map(\.size) == [Size(width: 4096, height: 2304)])
    }

    @Test func `should hand on each complete picture of the display`() throws {
        let (feed, frames) = (Feed(), Frames())
        let mac = screen(on: feed)
        try mac.start(onFrame: frames.add)
        feed.picture(FeedPicture(surface: Self.surface(), complete: true))
        feed.picture(FeedPicture(surface: Self.surface(), complete: true))
        #expect(frames.count == 2)
    }

    @Test func `should hand on nothing when the picture is unchanged or not drawn`() throws {
        let (feed, frames) = (Feed(), Frames())
        let mac = screen(on: feed)
        try mac.start(onFrame: frames.add)
        feed.picture(FeedPicture(surface: Self.surface(), complete: false))
        feed.picture(FeedPicture(surface: nil, complete: true))
        #expect(frames.count == 0)
    }

    @Test func `should start the feed again when it ends while the screen is started`() throws {
        let feed = Feed()
        let mac = screen(on: feed)
        try mac.start { _ in }
        feed.end()
        #expect(feed.starts.count == 2)
    }

    @Test func `should leave the feed ended when it ends after the screen stopped`() throws {
        let feed = Feed()
        let mac = screen(on: feed)
        try mac.start { _ in }
        mac.stop()
        feed.end()
        feed.picture(FeedPicture(surface: Self.surface(), complete: true))
        #expect(feed.starts.count == 1)
    }

    @Test func `should refuse to start when Screen Recording is not allowed`() {
        let feed = Feed(refusal: ScreenRecordingRefused())
        #expect(throws: ScreenRecordingRefused.self) { try screen(on: feed).start { _ in } }
    }

    static func surface() -> IOSurface? {
        IOSurfaceCreate([
            kIOSurfaceWidth: 4, kIOSurfaceHeight: 4, kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: 16, kIOSurfaceAllocSize: 64,
            kIOSurfacePixelFormat: UInt32(0x42475241),
        ] as CFDictionary)
    }
}
