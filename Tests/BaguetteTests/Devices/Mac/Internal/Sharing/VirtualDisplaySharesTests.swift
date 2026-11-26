import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDeviceFamilies
@testable import BaguetteDevice

/// This Mac shared to a viewer through a display of the viewer's shape: made
/// when the share starts, the main display if the viewer asks, reshaped as the
/// viewer turns, and gone — the main display given back — when it ends.
@Suite("VirtualDisplayShares")
struct VirtualDisplaySharesTests {
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
        private var _whileCreating: (@Sendable (Int) -> Void)?
        /// Work done as the Mac makes a display — given how many it has made, this one too.
        var whileCreating: (@Sendable (Int) -> Void)? {
            get { lock.withLock { _whileCreating } }
            set { lock.withLock { _whileCreating = newValue } }
        }

        /// Each display made is a new one to the Mac (a new `CGDirectDisplayID`),
        /// its UUID named by its serial — as CoreGraphics names it.
        /// `seenAsMain`: the Mac reports a display as main the moment it is
        /// made, as macOS briefly does.
        /// `makesOnly`: how many displays the Mac makes before it makes no more.
        init(makes: Bool = true, makesOnly limit: Int = .max, seenAsMain: Bool = false) {
            given(displays).create(named: .any, shape: .any, serial: .any).willProduce { [self] name, shape, serial in
                guard makes, created.count < limit else { return nil }
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
                whileCreating?(created.count)
                return made
            }
            given(arrangement).main.willProduce { [self] in lock.withLock { _main } }
            given(arrangement).makeMain(.any, freeingDock: .any).willProduce { [self] id, freeing in
                lock.withLock { _main = id; _events.append("main \(id)" + (freeing ? " freeing the Dock" : "")) }
                return true
            }
        }

        var shares: VirtualDisplayShares { VirtualDisplayShares(displays: displays, arrangement: arrangement) }

        func setMain(_ id: UInt32) { lock.withLock { _main = id } }
    }

    @Test func `should end a share whose display the Mac won't make again in the new shape`() {
        let mac = Mac(makesOnly: 1)
        let shares = mac.shares
        let id = shares.start(viewer: "iPhone", shape: Self.iPhone, use: .extra)!
        #expect(!shares.reshape(id, to: Self.turned))
        #expect(!shares.isSharing(id))
        #expect(mac.removed == 1)
    }

    @Test func `should free the Dock's edge when a share is made main, and not when main is given back`() {
        let mac = Mac()
        let shares = mac.shares
        let id = shares.start(viewer: "iPhone", shape: Self.iPhone, use: .main)!
        shares.end(id)
        #expect(mac.events.filter { $0.hasPrefix("main") } == ["main 7 freeing the Dock", "main 1"])
    }

    @Test func `should keep a later main share main when an earlier one ends, and give main back when the last one does`() {
        let mac = Mac()
        let shares = mac.shares
        let first = shares.start(viewer: "iPad", shape: Self.iPhone, use: .main)!    // display 7, main after 1
        let second = shares.start(viewer: "iPhone", shape: Self.iPhone, use: .main)! // display 8, main after 7
        shares.end(first)
        #expect(mac.main == 8)
        shares.end(second)
        #expect(mac.main == 1)
    }

    @Test func `should give main back to the Mac's own display whichever main share ends last`() {
        let mac = Mac()
        let shares = mac.shares
        let first = shares.start(viewer: "iPad", shape: Self.iPhone, use: .main)!
        let second = shares.start(viewer: "iPhone", shape: Self.iPhone, use: .main)!
        shares.end(second)
        #expect(mac.main == 7)
        shares.end(first)
        #expect(mac.main == 1)
    }

    @Test func `should end a share that its viewer left while it was being made again in a new shape`() {
        let mac = Mac()
        let shares = mac.shares
        let id = shares.start(viewer: "iPhone", shape: Self.iPhone, use: .extra)!
        let leaving = DispatchGroup()
        mac.whileCreating = { made in
            guard made == 2 else { return }
            leaving.enter()
            DispatchQueue.global().async { shares.end(id); leaving.leave() }
            _ = leaving.wait(timeout: .now() + 0.2)   // the leave arrives mid-turn
        }
        _ = shares.reshape(id, to: Self.turned)
        leaving.wait()
        #expect(!shares.isSharing(id))
        #expect(mac.removed == 2)   // the turned-from display, and the turned one
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
        #expect(mac.events == ["create 7", "main 7 freeing the Dock", "main 1", "remove 7", "create 8", "main 8 freeing the Dock"])
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
        #expect(ShareUse(wire: "main") == .main)
        #expect(ShareUse(wire: nil) == .extra)
        #expect(ShareUse(wire: "side") == nil)
    }
}
