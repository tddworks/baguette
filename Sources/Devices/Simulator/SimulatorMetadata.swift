import BaguetteDevice
import Foundation

/// Installed identities remain stable when the user renames a simulator.
public struct SimulatorMetadata: Equatable, Sendable {
    var deviceTypeIdentifier: String?
    var productFamily: String?
    var runtimeIdentifier: String?
    var runtimeVersion: String?

    var dictionary: [String: Any] {
        [
            "deviceTypeIdentifier": deviceTypeIdentifier as Any? ?? NSNull(),
            "productFamily": productFamily as Any? ?? NSNull(),
            "runtimeIdentifier": runtimeIdentifier as Any? ?? NSNull(),
            "runtimeVersion": runtimeVersion as Any? ?? NSNull(),
        ]
    }
}
