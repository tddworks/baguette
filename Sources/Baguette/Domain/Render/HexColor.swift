import BaguetteDevice
import Foundation

/// A `#RRGGBB` wire color parsed into unit RGB components. Malformed
/// input yields black so render paths never fail on a color string that
/// already passed request validation.
struct HexColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        red = Double((value >> 16) & 0xff) / 255
        green = Double((value >> 8) & 0xff) / 255
        blue = Double(value & 0xff) / 255
    }
}
