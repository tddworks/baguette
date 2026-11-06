import Testing
@testable import Baguette

@Suite("TextField")
struct TextFieldTests {
    private static let frame = Rect(origin: Point(x: 32, y: 183), size: Size(width: 338, height: 22))

    private func field(_ shows: String?, role: String = "AXTextField", subrole: String? = nil) throws -> TextField {
        try #require(AXNode(role: role, subrole: subrole, value: shows, identifier: "email", frame: Self.frame).textField)
    }

    @Test func `should be a text field when it holds text`() {
        for role in ["AXTextField", "AXTextArea", "AXSecureTextField"] {
            #expect(AXNode(role: role, frame: Self.frame).textField != nil)
        }
    }

    @Test func `should not be a text field when it's a switch`() {
        #expect(AXNode(role: "AXSwitch", label: "Email", frame: Self.frame).textField == nil)
    }

    @Test func `should not be a text field when it's a label saying the same thing`() {
        #expect(AXNode(role: "AXStaticText", label: "Email", frame: Self.frame).textField == nil)
    }

    @Test func `should know its name and what it shows`() throws {
        let field = try field("gary")
        #expect(field.name == "email")
        #expect(field.shows == "gary")
    }

    @Test func `should show nothing when it has no value`() throws {
        #expect(try field(nil).shows == "")
    }

    @Test func `should know when it has focus`() {
        let focused = AXNode(role: "AXTextField", frame: Self.frame, focused: true)
        let unfocused = AXNode(role: "AXTextField", frame: Self.frame, focused: false)
        #expect(focused.textField?.isFocused == true)
        #expect(unfocused.textField?.isFocused == false)
    }

    @Test func `should be secure by its role or its subrole`() throws {
        #expect(try field(nil, role: "AXSecureTextField").isSecure)
        #expect(try field(nil, role: "AXTextField", subrole: "AXSecureTextField").isSecure)
        #expect(try field(nil).isSecure == false)
    }

    @Test func `should read exact when it shows the text`() throws {
        #expect(try field("gary@example.com").reading(of: "gary@example.com") == .exact)
    }

    @Test func `should call other punctuation reformatted`() throws {
        #expect(try field("(555) 123-4567").reading(of: "5551234567") == .reformatted)
        #expect(try field("a—b").reading(of: "a--b") == .reformatted)
    }

    @Test func `should say a field differs when a letter changed`() throws {
        #expect(try field("gary@exampl.com").reading(of: "gary@example.com") == .differs)
    }

    @Test func `should say a field differs when its case changed`() throws {
        #expect(try field("Gary").reading(of: "gary") == .differs)
    }

    @Test func `should say a field differs when it shows nothing of punctuation it was told`() throws {
        #expect(try field("").reading(of: "--") == .differs)
    }

    @Test func `should read a secure field by its number of characters`() throws {
        let secure = try field("•••••••", subrole: "AXSecureTextField")
        #expect(secure.reading(of: "secret1") == .exact)
        #expect(secure.reading(of: "secret12") == .differs)
    }

    @Test func `should say a secure field differs when it still shows its placeholder`() throws {
        #expect(try field("Password", subrole: "AXSecureTextField").reading(of: "hunter22") == .differs)
    }
}
