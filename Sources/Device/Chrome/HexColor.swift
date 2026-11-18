import Foundation

/// A `#RRGGBB` wire color parsed into unit RGB components. Malformed
/// input yields black so render paths never fail on a color string that
/// already passed request validation.
public struct HexColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(_ hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        red = Double((value >> 16) & 0xff) / 255
        green = Double((value >> 8) & 0xff) / 255
        blue = Double(value & 0xff) / 255
    }
}
