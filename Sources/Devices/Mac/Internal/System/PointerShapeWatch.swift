import AppKit
import BaguetteDevice

/// The Mac's pointer shape, read from `NSCursor.currentSystem` 20 times a
/// second on a running run loop — without one the shape a process reads never
/// changes — until this process's parent is gone. Integration-only: which
/// readings are a change is `PointerShapeChanges`'.
public enum PointerShapeWatch {
    public static func sayChanges(_ say: @escaping @Sendable (String) -> Void) -> Never {
        // baguette's entry point is async, so a command runs off the main
        // thread; the main thread takes over and runs its run loop.
        DispatchQueue.main.async { watch(say) }
        while true { sleep(60) }
    }

    @MainActor
    private static func watch(_ say: @escaping @Sendable (String) -> Void) {
        let parent = ParentProcess(startedUnder: getppid())
        var changes = PointerShapeChanges()
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            if parent.isGone(now: getppid()) { exit(0) }
            guard let cursor = NSCursor.currentSystem,
                  let tiff = cursor.image.tiffRepresentation,
                  let png = png(of: cursor.image, scale: 2),
                  let shape = changes.read(image: tiff, png: png, hotspot: Point(x: cursor.hotSpot.x, y: cursor.hotSpot.y),
                                           size: Size(width: cursor.image.size.width, height: cursor.image.size.height))
            else { return }
            say(shape.line)
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.run()
    }

    /// The image drawn at `scale` pixels a point: its TIFF holds up to 10×,
    /// larger than a browser takes for a cursor (128 px a side).
    @MainActor
    private static func png(of image: NSImage, scale: Double) -> Data? {
        let (width, height) = (Int(image.size.width * scale), Int(image.size.height * scale))
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
