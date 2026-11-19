import Foundation

/// Minimal JSON-string escaper: backslash, quote, and the ASCII
/// control characters that JSON forbids unescaped. Sufficient for
/// embedding a log line into a `{"line":"…"}` envelope without
/// rebuilding the whole dict via JSONSerialization.
public func jsonEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count + 8)
    for ch in s.unicodeScalars {
        switch ch {
        case "\"":  out.append("\\\"")
        case "\\":  out.append("\\\\")
        case "\n":  out.append("\\n")
        case "\r":  out.append("\\r")
        case "\t":  out.append("\\t")
        case "\u{08}": out.append("\\b")
        case "\u{0C}": out.append("\\f")
        default:
            if ch.value < 0x20 {
                out.append(String(format: "\\u%04x", ch.value))
            } else {
                out.append(Character(ch))
            }
        }
    }
    return out
}
