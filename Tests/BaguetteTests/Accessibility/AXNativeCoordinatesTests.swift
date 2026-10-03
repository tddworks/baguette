import CoreGraphics
import Foundation
import Testing

@testable import Baguette

@Suite("AX native coordinates")
struct AXNativeCoordinatesTests {
    @Test func `four interface orientations preserve target centres in native HID points`() {
        let size = CGSize(width: 744, height: 1133)
        let cases: [(DeviceOrientation, CGRect, CGRect)] = [
            (.portrait, CGRect(x: 101, y: 316, width: 140, height: 70), CGRect(x: 101, y: 316, width: 140, height: 70)),
            (
                .landscapeLeft, CGRect(x: 190, y: 195, width: 140, height: 70),
                CGRect(x: 195, y: 803, width: 70, height: 140)
            ),
            (
                .landscapeRight, CGRect(x: 190, y: 195, width: 140, height: 70),
                CGRect(x: 479, y: 190, width: 70, height: 140)
            ),
            (
                .portraitUpsideDown, CGRect(x: 101, y: 316, width: 140, height: 70),
                CGRect(x: 503, y: 747, width: 140, height: 70)
            ),
        ]
        for (orientation, guest, native) in cases {
            let transform = AXFrameTransform(pointSize: size, orientation: orientation)
            #expect(transform.map(guest) == native)
            #expect(transform.unmap(CGPoint(x: native.midX, y: native.midY)) == CGPoint(x: guest.midX, y: guest.midY))
        }
    }

    @Test func `screen metadata does not infer panel dimensions from a partial application root`() throws {
        let node = AXNode(
            role: "AXApplication",
            frame: Rect(origin: Point(x: 200, y: 100), size: Size(width: 300, height: 500)),
            screen: AXScreen(width: 744, height: 1133, orientation: .landscapeLeft)
        )
        let json = try #require(JSONSerialization.jsonObject(with: Data(node.json.utf8)) as? [String: Any])
        let screen = try #require(json["screen"] as? [String: Any])
        #expect(screen["width"] as? Double == 744)
        #expect(screen["height"] as? Double == 1133)
        #expect(screen["orientation"] as? String == "landscape-left")
        let frame = try #require(json["frame"] as? [String: Any])
        #expect(frame["width"] as? Double == 300)
    }
}
