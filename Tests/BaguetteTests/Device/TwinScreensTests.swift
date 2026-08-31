import Foundation
import Mockable
import Testing
@testable import Baguette

@Suite("TwinScreens")
struct TwinScreensTests {
    private func makeDecoder() -> MockH264Decoder {
        let decoder = MockH264Decoder()
        given(decoder).configure(description: .any, onFrame: .any).willReturn()
        given(decoder).decode(.any).willReturn()
        given(decoder).stop().willReturn()
        return decoder
    }

    @Test func `opening a udid creates a findable hub`() {
        let screens = TwinScreens { self.makeDecoder() }
        let hub = screens.open(udid: "U1")
        #expect(screens.find(udid: "U1") === hub)
        #expect(screens.find(udid: "U2") == nil)
    }

    @Test func `closing removes the hub and tears down its decoder`() {
        let decoder = makeDecoder()
        let screens = TwinScreens { decoder }
        _ = screens.open(udid: "U1")
        screens.close(udid: "U1")
        #expect(screens.find(udid: "U1") == nil)
        verify(decoder).stop().called(1)
    }

    @Test func `reopening a udid replaces the hub and closes the old one`() {
        let first = makeDecoder()
        let second = makeDecoder()
        let decoders = LockedQueue(items: [first, second])
        let screens = TwinScreens { decoders.next() }
        let old = screens.open(udid: "U1")
        let new = screens.open(udid: "U1")
        #expect(old !== new)
        #expect(screens.find(udid: "U1") === new)
        verify(first).stop().called(1)
    }
}

/// Hands out queued decoders across `@Sendable` factory calls.
final class LockedQueue: @unchecked Sendable {
    private var items: [MockH264Decoder]
    init(items: [MockH264Decoder]) { self.items = items }
    func next() -> MockH264Decoder { items.removeFirst() }
}
