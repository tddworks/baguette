import Foundation

/// A failed disarm is safe only when a fresh, successful device-set listing proves the guest is gone.
enum SimctlCameraGuest {
    static func hasTerminated(
        udid: String,
        deviceSetPath: String? = nil,
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun")
    ) throws -> Bool {
        struct Devices: Decodable {
            struct Device: Decodable {
                let udid: String
                let state: String
            }
            let devices: [String: [Device]]
        }
        let output = try SimctlCapture.run(
            udid: udid,
            arguments: ["simctl"] + (deviceSetPath.map { ["--set", $0] } ?? []) + ["list", "devices", "--json"],
            xcrun: xcrun
        )
        let devices = try JSONDecoder().decode(Devices.self, from: Data(output.stdout.utf8))
        guard
            let device = devices.devices.values.joined().first(where: {
                $0.udid.caseInsensitiveCompare(udid) == .orderedSame
            })
        else { return true }
        return device.state == "Shutdown"
    }
}
