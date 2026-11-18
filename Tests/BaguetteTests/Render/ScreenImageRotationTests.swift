import CoreGraphics
import Foundation
import IOSurface
import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("ScreenImageRotation")
struct ScreenImageRotationTests {
    @Test(arguments: ScreenRotation.allCases)
    func `should preserve pixel locations and swap dimensions across quarter turns`(rotation: ScreenRotation) throws {
        // Distinct red intensities in a nonsquare 2 by 3 image expose mirroring and cropping.
        let values: [UInt8] = [20, 50, 80, 110, 140, 170]
        let data = Data(values.flatMap { [$0, 0, 0, 255] })
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(width: 2, height: 3, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let baseline = try #require(RealityKitDeviceRenderer.surface(from: image))
        let surface = try #require(RealityKitDeviceRenderer.surface(from: image, rotation: rotation))
        #expect(IOSurfaceGetWidth(surface) == (rotation.swapsDimensions ? 3 : 2))
        #expect(IOSurfaceGetHeight(surface) == (rotation.swapsDimensions ? 2 : 3))
        let before = pixels(baseline)
        let expected: [UInt8]
        switch rotation {
        case .none: expected = before
        case .quarter: expected = [before[1], before[3], before[5], before[0], before[2], before[4]]
        case .half: expected = Array(before.reversed())
        case .threeQuarters: expected = [before[4], before[2], before[0], before[5], before[3], before[1]]
        }
        #expect(pixels(surface) == expected)
    }

    @Test(arguments: ScreenRotation.allCases)
    func `should convert CMYK source images into RGB while rotating`(rotation: ScreenRotation) throws {
        let provider = try #require(CGDataProvider(data: Data(repeating: 0, count: 24) as CFData))
        let image = try #require(CGImage(width: 2, height: 3, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 8, space: CGColorSpaceCreateDeviceCMYK(), bitmapInfo: [],
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let surface = try #require(RealityKitDeviceRenderer.surface(from: image, rotation: rotation))
        #expect(pixels(surface).allSatisfy { $0 > 240 })
    }

    private func pixels(_ surface: IOSurface) -> [UInt8] {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        return (0..<IOSurfaceGetHeight(surface)).flatMap { y in
            (0..<IOSurfaceGetWidth(surface)).map { x in
                base[y * IOSurfaceGetBytesPerRow(surface) + x * 4 + 2]
            }
        }
    }
}
