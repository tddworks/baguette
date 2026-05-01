import Foundation

/// Single-line stderr log. Stdout is reserved for stream output / acks;
/// every other message goes here so it doesn't corrupt the wire.
func log(_ message: String) {
    fputs("[baguette] \(message)\n", stderr)
}
