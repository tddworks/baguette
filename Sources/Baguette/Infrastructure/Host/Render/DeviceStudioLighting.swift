import AppKit
import SceneKit

/// The neutral studio environment shared by live and still 3D rendering.
///
/// broad softboxes provide reflections without tinting or clipping device finishes.
enum DeviceStudioLighting {
    /// RealityKit environment exposure (2^exponent), calibrated so the
    /// Cosmic Orange finish matches the Quick Look rendering of the same
    /// `device.usdz` without clipping.
    static let intensityExponent: Float = 1.5

    static func apply(to scene: SCNScene) {
        scene.lightingEnvironment.contents = environment
        scene.lightingEnvironment.intensity = 1.5
    }

    private static let environment = NSImage(
        cgImage: equirectangularImage,
        size: NSSize(
            width: equirectangularImage.width,
            height: equirectangularImage.height
        )
    )

    /// Cover-glass reflection environment: near-black with two soft vertical
    /// softbox bands, HDR-bright so the streak reads through 0-opacity glass.
    /// Isolated to the glass layer via a per-entity image-based light, so
    /// body colors never change when the glass is enabled. Band placement
    /// follows the 3dsg screen-glass system; longitudes are tuned so front
    /// poses catch the bright band edge.
    static let glassStreakImage: CGImage = {
        let width = 1024
        let height = 512
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 32,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      | CGBitmapInfo.floatComponents.rawValue
              ) else {
            fatalError("glass streak context allocation failed")
        }
        func gray(_ value: CGFloat, alpha: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: colorSpace, components: [value, value, value, alpha])
                ?? CGColor(gray: value, alpha: alpha)
        }
        let size = CGSize(width: width, height: height)
        context.setFillColor(gray(0.012))
        context.fill(CGRect(origin: .zero, size: size))
        for (center, brightness) in [(0.45, 1.8), (0.79, 0.8)] {
            let bandWidth = size.width * 0.09
            let rect = CGRect(
                x: size.width * center - bandWidth / 2,
                y: size.height * 0.30,
                width: bandWidth,
                height: size.height * 0.62
            )
            context.saveGState()
            context.setShadow(
                offset: .zero,
                blur: size.width * 0.035,
                color: gray(1.2, alpha: 0.7)
            )
            context.setFillColor(gray(brightness))
            context.addPath(CGPath(
                roundedRect: rect,
                cornerWidth: bandWidth * 0.08,
                cornerHeight: bandWidth * 0.08,
                transform: nil
            ))
            context.fillPath()
            context.restoreGState()
        }
        guard let image = context.makeImage() else {
            fatalError("glass streak image creation failed")
        }
        return image
    }()

    static let equirectangularImage: CGImage = {
        let width = 1024
        let height = 512
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("studio environment context allocation failed")
        }

        let size = CGSize(width: width, height: height)
        let backgroundColors = [
            CGColor(gray: 0.36, alpha: 1),
            CGColor(gray: 0.30, alpha: 1),
            CGColor(gray: 0.12, alpha: 1),
            CGColor(gray: 0.25, alpha: 1),
        ] as CFArray
        let stops: [CGFloat] = [0, 0.32, 0.58, 1]
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: backgroundColors,
            locations: stops
        ) {
            context.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: 0, y: size.height),
                options: []
            )
        }

        let panelWidth = size.width * 0.15
        let panelHeight = size.height * 0.34
        let panelY = size.height * 0.38
        let centers: [CGFloat] = [-0.02, 0.24, 0.50, 0.76, 1.02]
        for (index, center) in centers.enumerated() {
            let rect = CGRect(
                x: size.width * center - panelWidth / 2,
                y: panelY,
                width: panelWidth,
                height: panelHeight
            )
            let brightness: CGFloat = index == 3 ? 1 : 0.88
            let corner = panelWidth * 0.18

            context.saveGState()
            context.setShadow(
                offset: .zero,
                blur: panelWidth * 0.18,
                color: CGColor(gray: 1, alpha: 0.55)
            )
            context.setFillColor(CGColor(gray: brightness, alpha: 1))
            context.addPath(CGPath(
                roundedRect: rect,
                cornerWidth: corner,
                cornerHeight: corner,
                transform: nil
            ))
            context.fillPath()
            context.restoreGState()

            let inner = rect.insetBy(
                dx: panelWidth * 0.12,
                dy: panelHeight * 0.14
            )
            context.setFillColor(CGColor(
                gray: min(brightness + 0.12, 1),
                alpha: 0.92
            ))
            context.addPath(CGPath(
                roundedRect: inner,
                cornerWidth: corner * 0.75,
                cornerHeight: corner * 0.75,
                transform: nil
            ))
            context.fillPath()

            let reflection = CGRect(
                x: rect.minX + panelWidth * 0.12,
                y: size.height * 0.20,
                width: panelWidth * 0.76,
                height: size.height * 0.18
            )
            context.saveGState()
            context.setShadow(
                offset: .zero,
                blur: panelWidth * 0.22,
                color: CGColor(gray: 1, alpha: 0.25)
            )
            context.setFillColor(CGColor(gray: brightness, alpha: 0.12))
            context.fillEllipse(in: reflection)
            context.restoreGState()
        }

        guard let image = context.makeImage() else {
            fatalError("studio environment image creation failed")
        }
        return image
    }()
}
