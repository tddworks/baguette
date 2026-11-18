import IOSurface
import Metal

/// A bounded set of IOSurface-backed Metal targets for real-time rendering.
///
/// Triple buffering keeps allocation constant and gives the GPU producer and
/// codec consumer separate surfaces during the normal live-stream pipeline.
/// Targets are single-sample; the render engine antialiases internally
/// before resolving into them.
final class MetalRenderTargetRing {
    struct Target {
        let surface: IOSurface
        /// Single-sample IOSurface texture the engine renders into and the
        /// video pipeline consumes.
        let texture: any MTLTexture

        /// Publish the completed Metal write to IOSurface consumers.
        func publish() {
            IOSurfaceLock(surface, [], nil)
            IOSurfaceUnlock(surface, [], nil)
        }
    }

    private static let bufferCount = 3
    private let targets: [Target]
    private var index = 0

    init(width: Int, height: Int, device: any MTLDevice) throws {
        let bytesPerRow = ((width * 4 + 63) / 64) * 64
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]

        targets = try (0..<Self.bufferCount).map { _ in
            guard let surface = IOSurfaceCreate([
                kIOSurfaceWidth: width,
                kIOSurfaceHeight: height,
                kIOSurfaceBytesPerElement: 4,
                kIOSurfaceBytesPerRow: bytesPerRow,
                kIOSurfaceAllocSize: bytesPerRow * height,
                kIOSurfacePixelFormat: UInt32(0x42475241),
            ] as CFDictionary),
            let texture = device.makeTexture(
                descriptor: descriptor,
                iosurface: surface,
                plane: 0
            ) else {
                throw DeviceModelError.renderFailed
            }
            return Target(surface: surface, texture: texture)
        }
    }

    func next() -> Target {
        let target = targets[index]
        index = (index + 1) % targets.count
        return target
    }
}
