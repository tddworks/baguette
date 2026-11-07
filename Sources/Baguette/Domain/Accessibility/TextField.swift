import Foundation

/// How a field's text compares with what it was told to hold.
enum FieldReading: Equatable, Sendable {
    case exact
    /// The same letters and digits with other punctuation: a phone field's
    /// formatting, or smart punctuation.
    case reformatted
    case differs
}

/// A box on screen that holds text an agent can replace, as one read saw it. Only
/// `AXNode.textField` builds one, so nothing else can be filled.
struct TextField: Equatable, Sendable {
    fileprivate static let roles: Set<String> = ["AXTextField", "AXTextArea", "AXSecureTextField"]
    private static let secure = "AXSecureTextField"

    let name: String
    /// An empty field reads as its placeholder, and accessibility can't tell the two apart.
    let shows: String
    let isSecure: Bool
    let isFocused: Bool

    fileprivate init(_ node: AXNode) {
        name = node.offerName
        shows = node.value ?? ""
        isSecure = node.role == Self.secure || node.subrole == Self.secure
        isFocused = node.focused
    }

    func reading(of text: String) -> FieldReading {
        if isSecure { return readsSecurely(as: text) ? .exact : .differs }
        if shows == text { return .exact }
        let wanted = Self.lettersAndDigits(text)
        return !wanted.isEmpty && wanted == Self.lettersAndDigits(shows) ? .reformatted : .differs
    }

    /// `text` as it may be repeated back: a password's characters never are.
    func wanted(_ text: String) -> String {
        isSecure ? "\(text.count) characters" : "\"\(text)\""
    }

    /// Its value is dots, so only their number says anything. A value with letters
    /// in it is the placeholder, whatever its length.
    private func readsSecurely(as text: String) -> Bool {
        shows.count == text.count && Self.lettersAndDigits(shows).isEmpty
    }

    private static func lettersAndDigits(_ text: String) -> String {
        text.filter { $0.isLetter || $0.isNumber }
    }
}

extension AXNode {
    /// This element as a text field, or `nil` when it isn't one.
    var textField: TextField? {
        TextField.roles.contains(role) ? TextField(self) : nil
    }
}
