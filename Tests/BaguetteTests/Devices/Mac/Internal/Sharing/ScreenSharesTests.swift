import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// This Mac shared to a viewer through a display of the viewer's shape: made
/// when the share starts, the main display if the viewer asks, reshaped as the
/// viewer turns, and gone — the main display given back — when it ends.
@Suite("ScreenShares")
struct ScreenSharesTests {
    static let iPhone = SharedScreenShape(viewer: ViewerScreen(points: Size(width: 402, height: 874), pixelsPerPoint: 3),
                                          room: .standard)
    static let turned = SharedScreenShape(viewer: ViewerScreen(points: Size(width: 874, height: 402), pixelsPerPoint: 3),
                                          room: .standard)

    /// The Mac's displays, played by the test: it remembers what it was asked.
    final class Mac: @unchecked Sendable {
        let displays = MockVirtualDisplays()
        let arrangement = MockDisplayArrangement()
        private let lock = NSLock()
        private var _main: UInt32 = 1
        private var _created: [(name: String, shape: SharedScreenShape, serial: UInt32)] = []
        private var _removed = 0
        private var _events: [String] = []
        /// What the Mac was told, in order: "main 7", "remove 7", "create 8".
        var events: [String] { lock.withLock { _events } }
        var main: UInt32 { lock.withLock { _main } }
        var created: [(name: String, shape: SharedScreenShape, serial: UInt32)] { lock.withLock { _created } }
        var removed: Int { lock.withLock { _removed } }

        /// Each display made is a new one to the Mac (a new `CGDirectDisplayID`),
        /// its UUID named by its serial — as CoreGraphics names it.
        /// `seenAsMain`: the Mac reports a display as main the moment it is
        /// made, as macOS briefly does.
        init(makes: Bool = true, seenAsMain: Bool = false) {
            given(displays).create(named: .any, shape: .any, serial: .any).willProduce { [self] name, shape, serial in
                guard makes else { return nil }
                let made = MockVirtualDisplay()
                let id = lock.withLock { () -> UInt32 in
                    _created.append((name, shape, serial))
                    let id = UInt32(6 + _created.count)
                    _events.append("create \(id)")
                    if seenAsMain { _main = id }
                    return id
                }
                given(made).uuid.willReturn("VIRTUAL-\(serial)")
                given(made).id.willReturn(id)
                given(made).remove().willProduce { [self] in lock.withLock { _removed += 1; _events.append("remove \(id)") } }
                return made
            }
            given(arrangement).main.willProduce { [self] in lock.withLock { _main } }
            given(arrangement).makeMain(.any).willProduce { [self] id in
                lock.withLock { _main = id; _events.append("main \(id)") }
                return true
            }
        }

        var shares: ScreenShares { ScreenShares(displays: displays, arrangement: arrangement) }

        func setMain(_ id: UInt32) { lock.withLock { _main = id } }
    }

    @Test func `should share the Mac through a new display of the viewer's shape, named for the viewer`() {
        let mac = Mac()
        let id = mac.shares.start(viewer: "iPhone", shape: Self.iPhone, use: .extra)
        #expect(id == "VIRTUAL-1")
        #expect(mac.created.map(\.name) == ["baguette – iPhone"])
        #expect(mac.created.map(\.shape) == [Self.iPhone])
    }

    @Test func `should leave the main display as it is when shared as an extra display`() {
        let mac = Mac()
        _ = mac.shares.start(viewer: "iPhone", shape: Self.iPhone, use: .extra)
        #expect(mac.main == 1)
    }

    @Test func `should make the shared display the main one when asked, and give the main display back when it ends`() {
        let mac = Mac()
        let shares = mac.shares
        let id = shares.start(viewer: "iPhone", shape: Self.iPhone, use: .main)
        #expect(mac.main == 7)
        shares.end(id!)
        #expect(mac.main == 1)
        #expect(mac.removed == 1)
    }

    @Test func `should give back the main display from before the share, though the Mac calls the new display main once made`() {
        let mac = Mac(seenAsMain: true)
        let shares = mac.shares
        let id = shares.start(viewer: "iPhone", shape: Self.iPhone, use: .main)!
        mac.setMain(7)
        shares.end(id)
        #expect(mac.main == 1)
    }

    @Test func `should make the display again in the viewer's new shape when it turns, keeping its id`() {
        let mac = Mac()
        let shares = mac.shares
        let id = shares.start(viewer: "iPhone", shape: Self.iPhone, use: .extra)!
        #expect(shares.reshape(id, to: Self.turned))
        #expect(mac.created.map(\.shape) == [Self.iPhone, Self.turned])
        #expect(Set(mac.created.map(\.serial)).count == 1)
        #expect(mac.removed == 1)
        #expect(shares.isSharing(id))
    }

    @Test func `should keep a turned main display main, and give back the main display from before the share`() {
        let mac = Mac()
        let shares = mac.shares
        let id = shares.start(viewer: "iPhone", shape: Self.iPhone, use: .main)!
        _ = shares.reshape(id, to: Self.turned)
        #expect(mac.main == 8)
        shares.end(id)
        #expect(mac.main == 1)
    }

    @Test func `should hand main back before removing a turned main display, which macOS removes slowly while it is main`() {
        let mac = Mac()
        let shares = mac.shares
        let id = shares.start(viewer: "iPhone", shape: Self.iPhone, use: .main)!
        _ = shares.reshape(id, to: Self.turned)
        #expect(mac.events == ["create 7", "main 7", "main 1", "remove 7", "create 8", "main 8"])
    }

    @Test func `should give each viewer's display its own serial, so each has its own id`() {
        let mac = Mac()
        let shares = mac.shares
        let first = shares.start(viewer: "iPhone", shape: Self.iPhone, use: .extra)
        let second = shares.start(viewer: "iPad", shape: Self.iPhone, use: .extra)
        #expect(first != second)
    }

    @Test func `should know the pixels each shared display was made with, through a turn`() {
        let mac = Mac()
        let shares = mac.shares
        let id = shares.start(viewer: "iPhone", shape: Self.iPhone, use: .extra)!
        #expect(shares.pixels(of: id) == Size(width: 1206, height: 2622))
        _ = shares.reshape(id, to: Self.turned)
        #expect(shares.pixels(of: id) == Size(width: 2622, height: 1206))
        shares.end(id)
        #expect(shares.pixels(of: id) == nil)
    }

    @Test func `should reshape nothing when no share has the id`() {
        #expect(!Mac().shares.reshape("nope", to: Self.turned))
    }

    @Test func `should remove the display when the share ends, once`() {
        let mac = Mac()
        let shares = mac.shares
        let id = shares.start(viewer: "iPhone", shape: Self.iPhone, use: .extra)!
        shares.end(id)
        shares.end(id)
        #expect(mac.removed == 1)
        #expect(!shares.isSharing(id))
    }

    @Test func `should share nothing when the Mac won't make the display`() {
        let mac = Mac(makes: false)
        #expect(mac.shares.start(viewer: "iPhone", shape: Self.iPhone, use: .main) == nil)
        #expect(mac.main == 1)
    }

    @Test func `should read how a viewer uses the display by its wire name, extra by default`() {
        #expect(ScreenShares.Use(wire: "main") == .main)
        #expect(ScreenShares.Use(wire: nil) == .extra)
        #expect(ScreenShares.Use(wire: "side") == nil)
    }
}
