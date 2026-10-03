import CoreGraphics
import Testing

@testable import Baguette

@Suite("AXFrameTransform")
struct AXFrameTransformTests {
    @Test(arguments: [
        (DeviceOrientation.portrait, CGRect(x: 50, y: 80, width: 84, height: 48)),
        (.portraitUpsideDown, CGRect(x: 268, y: 746, width: 84, height: 48)),
        (.landscapeLeft, CGRect(x: 80, y: 740, width: 48, height: 84)),
        (.landscapeRight, CGRect(x: 274, y: 50, width: 48, height: 84)),
    ])
    func `noncentral UIKit rectangles and hit tests use native panel coordinates`(
        orientation: DeviceOrientation, expected: CGRect
    ) {
        let transform = AXFrameTransform(
            pointSize: CGSize(width: 402, height: 874), orientation: orientation
        )
        let raw = CGRect(x: 50, y: 80, width: 84, height: 48)
        let mapped = transform.map(raw)
        #expect(mapped == expected)
        #expect(transform.unmap(CGPoint(x: mapped.midX, y: mapped.midY)) == CGPoint(x: raw.midX, y: raw.midY))
    }
}
