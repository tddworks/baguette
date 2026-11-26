import Foundation
@testable import Baguette
@testable import BaguetteDeviceFamilies

/// What `devicectl` writes about one connected phone, for the adapters
/// that ask it where the phone's tunnel is and how big its screen is.
enum PhoneJSON {
    static let identifier = UUID(uuidString: "30546CC9-90DC-5F06-87D3-42D2C2E913D1")!
    /// The phone's end of its tunnel, and this Mac's on the same prefix.
    static let tunnel = "fdd3:48cf:f69f::1"
    static let mac = "fdd3:48cf:f69f::2"

    /// `devicectl list devices`, the phone's tunnel up at `tunnelAddress` or down.
    static func listing(tunnelAddress: String?, identifier: UUID = identifier) -> Data {
        let address = tunnelAddress.map { #","tunnelIPAddress":"\#($0)""# } ?? ""
        return Data(#"""
            {"info":{"outcome":"success"},"result":{"devices":[
            {"identifier":"\#(identifier.uuidString)",
             "connectionProperties":{"pairingState":"paired","tunnelState":"\#(tunnelAddress == nil ? "disconnected" : "connected")","transportType":"wired"\#(address)},
             "deviceProperties":{"name":"han's iPhone","bootState":"booted","developerModeStatus":"enabled","osVersionNumber":"27.0.1"},
             "hardwareProperties":{"udid":"00008160-001239C43AA0000A","reality":"physical","productType":"iPhone19,7",
               "marketingName":"iPhone 18 Pro Max","platform":"iOS","deviceType":"iPhone"}}]}}
            """#.utf8)
    }

    /// `devicectl device info displays`: a 1320 × 2868 primary display.
    static let displays = Data(#"""
        {"info":{"outcome":"success"},"result":{"displays":[
        {"displayId":1,"primary":true,"name":"LCD","nativeSize":[1320,2868],"bounds":[[0,0],[1320,2868]]}]}}
        """#.utf8)

    /// A fake devicectl answering `list devices` with `listings` in turn
    /// (the last one from then on) and `device info displays` with `displays`.
    static func devicectl(listings: [Data]) -> FakeDevicectl {
        let fake = FakeDevicectl()
        let remaining = Listings(listings)
        fake.writeFile = { path, arguments in
            let json = arguments.contains("displays") ? displays : remaining.next()
            FileManager.default.createFile(atPath: path, contents: json)
        }
        return fake
    }

    private final class Listings: @unchecked Sendable {
        private let lock = NSLock()
        private var listings: [Data]
        init(_ listings: [Data]) { self.listings = listings }
        func next() -> Data {
            lock.withLock { listings.count > 1 ? listings.removeFirst() : listings.first ?? Data() }
        }
    }
}
