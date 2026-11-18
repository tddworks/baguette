import Testing

@testable import Baguette
@testable import BaguetteDevice

@Suite("HexColor")
struct HexColorTests {
    @Test
    func `should read a hex finish color into unit components`() {
        let color = HexColor("#D96129")

        #expect(abs(color.red - 217.0 / 255.0) < 0.0001)
        #expect(abs(color.green - 97.0 / 255.0) < 0.0001)
        #expect(abs(color.blue - 41.0 / 255.0) < 0.0001)
    }

    @Test
    func `should read pure color channels exactly`() {
        #expect(HexColor("#FF0000") == HexColor(red: 1, green: 0, blue: 0))
        #expect(HexColor("#00FF00") == HexColor(red: 0, green: 1, blue: 0))
        #expect(HexColor("#0000FF") == HexColor(red: 0, green: 0, blue: 1))
    }

    @Test
    func `should fall back to black when the hex color is malformed`() {
        #expect(HexColor("#GGGGGG") == HexColor(red: 0, green: 0, blue: 0))
        #expect(HexColor("") == HexColor(red: 0, green: 0, blue: 0))
    }
}
