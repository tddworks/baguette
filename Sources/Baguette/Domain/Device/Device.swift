import Foundation
import Mockable

/// A physical phone whose companion app is connected to this host —
/// the identity baguette lists it under, taken verbatim from the
/// companion's hello.
struct Device: Equatable, Sendable {
    let udid: String
    let name: String
    let model: String
    let capabilities: [String]

    init(udid: String, name: String, model: String, capabilities: [String]) {
        self.udid = udid
        self.name = name
        self.model = model
        self.capabilities = capabilities
    }

    init(hello: TwinHello) {
        self.init(
            udid: hello.udid,
            name: hello.name,
            model: hello.model,
            capabilities: hello.capabilities
        )
    }
}

/// The host's collection of connected physical devices — the aggregate
/// beside `Simulators`. Membership is driven by companion sockets
/// connecting and disconnecting; the production impl lives in
/// Infrastructure.
@Mockable
protocol Devices: AnyObject, Sendable {
    var all: [Device] { get }
}

extension Devices {
    func find(udid: String) -> Device? {
        all.first { $0.udid == udid }
    }

    /// JSON projection consumed by the `/devices.json` endpoint.
    /// Sorted keys keep diffs and snapshot tests readable. A single
    /// `connected` section for now — paired-but-offline devices can
    /// join it later without breaking consumers.
    var listJSON: String {
        let dict: [String: Any] = [
            "connected": all.map { device in
                [
                    "udid": device.udid,
                    "name": device.name,
                    "model": device.model,
                    "capabilities": device.capabilities,
                ]
            }
        ]
        let data = try! JSONSerialization.data(
            withJSONObject: dict, options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }
}
