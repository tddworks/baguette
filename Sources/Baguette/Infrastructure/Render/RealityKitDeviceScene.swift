import AppKit
import Foundation
import IOSurface
import Metal
import MetalPerformanceShaders
import RealityKit

/// Persistent RealityKit adapter for one live 3D stream connection.
///
/// RealityKit is the same engine Quick Look uses for USDZ, so authored
/// device finishes tone-map identically to `device.usdz` previews. Model
/// resolution, variant authoring, entity loading, camera, and lighting
/// happen once. Per simulator frame only the screen drawable and the
/// render target change.
///
/// RealityKit's renderer is main-actor bound; every entry point hops to
/// the main queue, mirroring the HID input path's MainActor requirement.
final class RealityKitDeviceScene: DeviceScene, @unchecked Sendable {
    private let plan: DeviceRenderPlan
    private let scratch: URL

    // MainActor-confined RealityKit state. Access only via onMain.
    private var renderer: RealityRenderer!
    private var wrapper: Entity!
    private var cameraEntity: PerspectiveCamera!
    private var cameraFraming: DeviceCameraFraming!
    private var screenEntity: ModelEntity!
    private var screenMaterialIndex: Int = 0
    private var screenTexture: LowLevelTexture?
    private var screenSourceSize: RenderDimensions?
    private var screenContentRegion: ContentRegion?
    private var screenLocalCorners: ScreenLocalCorners!
    private(set) var screenQuad: ScreenQuad?
    private var renderTargets: MetalRenderTargetRing!
    private var metalDevice: (any MTLDevice)!
    private var commandQueue: (any MTLCommandQueue)!
    private var supersampled: (texture: any MTLTexture, output: RealityRenderer.CameraOutput)?
    private var downscale: MPSImageLanczosScale?

    init(
        plan: DeviceRenderPlan,
        assets: VerifiedDeviceAssets = VerifiedDeviceAssets()
    ) throws {
        self.plan = plan
        scratch = FileManager.default.temporaryDirectory
            .appending(path: "baguette-live-3d-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        do {
            let assetURL = try assets.resolve(plan.model)
            let sceneURL = try Self.preparedSceneURL(
                assetURL: assetURL,
                selections: plan.variants,
                scratch: scratch
            )
            try Self.onMain {
                try self.buildStage(sceneURL: sceneURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    func render(screen surface: IOSurface) throws -> IOSurface {
        try Self.onMain {
            try self.renderFrame(surface)
        }
    }

    func update(camera requested: Device3DCamera) {
        Self.onMain {
            self.wrapper.orientation = Self.orientation(requested.rotation)
            self.cameraEntity.position.z = Float(
                self.cameraFraming.distance(at: requested.zoom)
            )
            self.screenQuad = self.projectedScreenQuad(
                rotation: requested.rotation,
                zoom: requested.zoom
            )
        }
    }

    func update(pose: Attitude, zoom: Double) {
        Self.onMain {
            self.wrapper.orientation = simd_quatf(
                ix: Float(pose.x), iy: Float(pose.y),
                iz: Float(pose.z), r: Float(pose.w)
            ).normalized
            self.cameraEntity.position.z = Float(
                self.cameraFraming.distance(at: zoom)
            )
            self.screenQuad = ScreenQuadProjection.project(
                corners: self.screenLocalCorners,
                attitude: pose,
                distance: self.cameraFraming.distance(at: zoom),
                fieldOfViewDegrees: self.cameraFraming.fieldOfViewDegrees,
                aspect: Double(self.plan.outputSize.width) / Double(self.plan.outputSize.height)
            )
        }
    }

    /// Where the screen mesh lands in the output image for the given pose —
    /// pure trig mirroring the same rotation and perspective camera the
    /// renderer uses, so the browser can map clicks back onto the screen
    /// without ray casting into the GPU scene.
    @MainActor
    private func projectedScreenQuad(rotation: DeviceRotation, zoom: Double) -> ScreenQuad {
        ScreenQuadProjection.project(
            corners: screenLocalCorners,
            rotation: rotation,
            distance: cameraFraming.distance(at: zoom),
            fieldOfViewDegrees: cameraFraming.fieldOfViewDegrees,
            aspect: Double(plan.outputSize.width) / Double(plan.outputSize.height)
        )
    }

    // MARK: - stage construction (MainActor)

    @MainActor
    private func buildStage(sceneURL: URL) throws {
        let definition = plan.model.definition
        let loaded: Entity
        do {
            loaded = try Entity.loadSynchronously(contentsOf: sceneURL)
        } catch {
            throw DeviceModelError.sceneLoadFailed(sceneURL.path)
        }
        guard let subject = Self.findEntity(named: definition.scene.rootNode, under: loaded) else {
            throw DeviceModelError.sceneNodeNotFound(definition.scene.rootNode)
        }
        Self.applyMaterialColors(
            plan.variants.reduce(into: [:]) { colors, selection in
                colors.merge(selection.materialColors) { _, requested in requested }
            },
            under: subject
        )
        guard let screen = Self.findScreenEntity(
            under: subject,
            explicitName: definition.scene.screenNode,
            materialName: definition.scene.screenMaterial
        ) else {
            throw DeviceModelError.sceneNodeNotFound(
                definition.scene.screenNode ?? definition.scene.screenMaterial
            )
        }
        screenEntity = screen
        screenMaterialIndex = screen.model?.materials.firstIndex {
            $0.name == definition.scene.screenMaterial
        } ?? 0
        if plan.screenGlass {
            try Self.addCoverGlass(over: screen, subject: subject)
        }

        let stage = try RealityRenderer()
        renderer = stage
        let wrapperEntity = Entity()
        wrapperEntity.name = "baguette-device"
        subject.removeFromParent()
        wrapperEntity.addChild(subject)
        stage.entities.append(wrapperEntity)
        wrapper = wrapperEntity

        let bounds = subject.visualBounds(relativeTo: wrapperEntity)
        let extents = bounds.extents
        guard extents.x > 0 || extents.y > 0 || extents.z > 0 else {
            throw DeviceModelError.sceneHasNoGeometry
        }
        subject.position -= bounds.center
        wrapperEntity.orientation = Self.orientation(plan.rotation)

        let screenBounds = screen.visualBounds(relativeTo: wrapperEntity)
        screenLocalCorners = ScreenLocalCorners.from(
            center: Vector3(
                x: Double(screenBounds.center.x),
                y: Double(screenBounds.center.y),
                z: Double(screenBounds.center.z)
            ),
            extents: Vector3(
                x: Double(screenBounds.extents.x),
                y: Double(screenBounds.extents.y),
                z: Double(screenBounds.extents.z)
            )
        )

        let framing = DeviceCameraFraming.fit(
            subjectWidth: Double(extents.x),
            subjectHeight: Double(extents.y),
            subjectDepth: Double(extents.z),
            viewport: plan.outputSize
        )
        cameraFraming = framing
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = Float(framing.fieldOfViewDegrees)
        camera.camera.near = 0.01
        camera.camera.far = 10_000
        camera.position = [0, 0, Float(framing.distance(at: 1))]
        stage.entities.append(camera)
        stage.activeCamera = camera
        cameraEntity = camera

        stage.cameraSettings.antialiasing = .multisample4X
        stage.cameraSettings.colorBackground = .color(Self.backgroundColor(plan.background))
        stage.lighting.resource = try EnvironmentResource(
            equirectangular: DeviceStudioLighting.equirectangularImage
        )
        stage.lighting.intensityExponent = DeviceStudioLighting.intensityExponent

        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw DeviceModelError.renderFailed
        }
        metalDevice = device
        commandQueue = queue
        renderTargets = try MetalRenderTargetRing(
            width: plan.outputSize.width,
            height: plan.outputSize.height,
            device: device
        )

        screenQuad = projectedScreenQuad(rotation: plan.rotation, zoom: 1)

        // The engine's MSAA covers lit geometry but skips the unlit
        // screen pass, so its content edge stair-steps on tilted poses.
        // Rendering at 2× and box-downsampling restores edge coverage
        // for every pass; skipped only when 2× would exceed sane bounds.
        let scaled = RenderDimensions(
            width: plan.outputSize.width * 2,
            height: plan.outputSize.height * 2
        )
        if max(scaled.width, scaled.height) <= 4096 {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb,
                width: scaled.width,
                height: scaled.height,
                mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw DeviceModelError.renderFailed
            }
            supersampled = (
                texture: texture,
                output: try RealityRenderer.CameraOutput(
                    .singleProjection(colorTexture: texture)
                )
            )
            downscale = MPSImageLanczosScale(device: device)
        }
    }

    // MARK: - per-frame rendering (MainActor)

    @MainActor
    private func renderFrame(_ surface: IOSurface) throws -> IOSurface {
        let sourceSize = RenderDimensions(
            width: IOSurfaceGetWidth(surface),
            height: IOSurfaceGetHeight(surface)
        )
        let texture = try screenLowLevelTexture(for: sourceSize)
        try blit(surface, into: texture, size: sourceSize)

        let target = renderTargets.next()
        let output = try supersampled?.output ?? RealityRenderer.CameraOutput(
            .singleProjection(colorTexture: target.texture)
        )
        let finished = DispatchSemaphore(value: 0)
        try renderer.updateAndRender(
            deltaTime: 1.0 / 60.0,
            cameraOutput: output,
            onComplete: { _ in finished.signal() }
        )
        finished.wait()
        if let supersampled, let downscale {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw DeviceModelError.renderFailed
            }
            downscale.encode(
                commandBuffer: commandBuffer,
                sourceTexture: supersampled.texture,
                destinationTexture: target.texture
            )
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
        target.publish()
        return target.surface
    }

    /// The screen streams through one persistent low-level texture sized
    /// to the simulator surface; UV placement handles cover/contain/stretch.
    @MainActor
    private func screenLowLevelTexture(
        for sourceSize: RenderDimensions
    ) throws -> LowLevelTexture {
        if let screenTexture, screenSourceSize == sourceSize {
            return screenTexture
        }
        let texture = try LowLevelTexture(descriptor: .init(
            pixelFormat: .bgra8Unorm_srgb,
            width: sourceSize.width,
            height: sourceSize.height,
            textureUsage: [.shaderRead, .shaderWrite]
        ))

        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .white, texture: .init(try .init(from: texture)))
        let placement = plan.fit.placement(
            source: sourceSize,
            target: plan.model.definition.scene.textureSize
        )
        material.textureCoordinateTransform = .init(
            offset: [Float(placement.offsetX), Float(placement.offsetY)],
            scale: [Float(placement.scaleX), Float(placement.scaleY)]
        )
        if var model = screenEntity.model {
            var materials = model.materials
            materials[screenMaterialIndex] = material
            model.materials = materials
            screenEntity.model = model
        }
        // The visible window keeps a permanent 2-pixel black border, and
        // per-frame blits cover only the interior. Texture filtering fades
        // content into the border over a texel, so the display's content
        // edge resolves smoothly instead of dot-dashing at the mesh edge.
        try blackFill(texture, size: sourceSize)
        screenContentRegion = placement.contentRegion(in: sourceSize, inset: 2)
        screenTexture = texture
        screenSourceSize = sourceSize
        return texture
    }

    @MainActor
    private func blackFill(_ texture: LowLevelTexture, size: RenderDimensions) throws {
        let bytesPerRow = size.width * 4
        var opaqueBlack = [UInt8](repeating: 0, count: bytesPerRow * size.height)
        for index in stride(from: 3, to: opaqueBlack.count, by: 4) {
            opaqueBlack[index] = 255
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: size.width,
            height: size.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let black = metalDevice.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw DeviceModelError.renderFailed
        }
        black.replace(
            region: MTLRegionMake2D(0, 0, size.width, size.height),
            mipmapLevel: 0,
            withBytes: opaqueBlack,
            bytesPerRow: bytesPerRow
        )
        let destination = texture.replace(using: commandBuffer)
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw DeviceModelError.renderFailed
        }
        encoder.copy(from: black, to: destination)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    @MainActor
    private func blit(
        _ surface: IOSurface,
        into texture: LowLevelTexture,
        size: RenderDimensions
    ) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: size.width,
            height: size.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let source = metalDevice.makeTexture(
            descriptor: descriptor,
            iosurface: surface,
            plane: 0
        ) else {
            throw DeviceModelError.screenImageInvalid
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw DeviceModelError.renderFailed
        }
        let destination = texture.replace(using: commandBuffer)
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw DeviceModelError.renderFailed
        }
        if let region = screenContentRegion, region.width > 0, region.height > 0 {
            encoder.copy(
                from: source,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: region.x, y: region.y, z: 0),
                sourceSize: MTLSize(width: region.width, height: region.height, depth: 1),
                to: destination,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: region.x, y: region.y, z: 0)
            )
        } else {
            encoder.copy(from: source, to: destination)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - entity helpers

    @MainActor
    private static func findEntity(named name: String, under root: Entity) -> Entity? {
        if root.name == name { return root }
        return root.findEntity(named: name)
    }

    @MainActor
    private static func findScreenEntity(
        under subject: Entity,
        explicitName: String?,
        materialName: String
    ) -> ModelEntity? {
        if let explicitName,
           let found = findEntity(named: explicitName, under: subject) as? ModelEntity {
            return found
        }
        if let model = subject as? ModelEntity,
           model.model?.materials.contains(where: { $0.name == materialName }) == true {
            return model
        }
        for child in subject.children {
            if let found = findScreenEntity(
                under: child,
                explicitName: nil,
                materialName: materialName
            ) {
                return found
            }
        }
        return nil
    }

    /// A cover-glass layer cloned from the display geometry: black dielectric
    /// at zero opacity, so only fresnel-weighted reflections of a dedicated
    /// streak environment composite over the unlit screen. The per-entity
    /// image-based light keeps body lighting untouched.
    @MainActor
    private static func addCoverGlass(over screen: ModelEntity, subject: Entity) throws {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .black)
        material.blending = .transparent(opacity: .init(floatLiteral: 0.0))
        material.roughness = 0.1
        material.metallic = 0.0

        let glass = screen.clone(recursive: false)
        glass.name = "baguette-cover-glass"
        if var model = glass.model {
            model.materials = Array(
                repeating: material,
                count: max(model.materials.count, 1)
            )
            glass.model = model
        }

        // Lift along the display normal — the thinnest local axis, signed
        // outward (the screen face sits away from the device's center).
        let bounds = screen.visualBounds(relativeTo: screen)
        let extents = bounds.extents
        let lift = max(extents.x, max(extents.y, extents.z)) * 0.002
        var axis = SIMD3<Float>(1, 0, 0)
        if extents.y <= extents.x, extents.y <= extents.z {
            axis = SIMD3<Float>(0, 1, 0)
        } else if extents.z <= extents.x, extents.z <= extents.y {
            axis = SIMD3<Float>(0, 0, 1)
        }
        let deviceCenter = subject.visualBounds(relativeTo: screen).center
        let outward: Float = simd_dot(bounds.center - deviceCenter, axis) < 0 ? -1 : 1
        glass.transform = Transform(translation: axis * lift * outward)
        screen.addChild(glass)

        let streak = try EnvironmentResource(
            equirectangular: DeviceStudioLighting.glassStreakImage
        )
        glass.components.set(ImageBasedLightComponent(source: .single(streak)))
        glass.components.set(ImageBasedLightReceiverComponent(imageBasedLight: glass))
    }

    /// Material appearance variants replace the authored base texture with
    /// the declared finish color; a tint alone would multiply into the
    /// texture and produce muddy mixes instead of the declared finish.
    @MainActor
    private static func applyMaterialColors(
        _ colors: [String: String],
        under entity: Entity
    ) {
        if var model = entity.components[ModelComponent.self] {
            var changed = false
            model.materials = model.materials.map { material in
                guard let name = material.name,
                      let hex = colors[name],
                      var adjusted = material as? PhysicallyBasedMaterial else {
                    return material
                }
                let color = HexColor(hex)
                adjusted.baseColor = .init(tint: NSColor(
                    red: color.red,
                    green: color.green,
                    blue: color.blue,
                    alpha: 1
                ))
                changed = true
                return adjusted
            }
            if changed { entity.components.set(model) }
        }
        for child in entity.children {
            applyMaterialColors(colors, under: child)
        }
    }

    // MARK: - value helpers

    private static func preparedSceneURL(
        assetURL: URL,
        selections: [DeviceVariantSelection],
        scratch: URL
    ) throws -> URL {
        let usdSelections = selections.filter { $0.kind == .usd }
        guard !usdSelections.isEmpty else { return assetURL }
        let stagedName = "device.\(assetURL.pathExtension)"
        let stagedAsset = scratch.appending(path: stagedName)
        try FileManager.default.createSymbolicLink(
            at: stagedAsset,
            withDestinationURL: assetURL
        )
        let overlay = try USDVariantOverlay.make(
            assetReference: stagedName,
            selections: usdSelections
        )
        let overlayURL = scratch.appending(path: "variants.usda")
        try overlay.write(to: overlayURL, atomically: true, encoding: .utf8)
        return overlayURL
    }

    private static func orientation(_ rotation: DeviceRotation) -> simd_quatf {
        simd_quatf(angle: radians(rotation.z), axis: [0, 0, 1])
            * simd_quatf(angle: radians(rotation.y), axis: [0, 1, 0])
            * simd_quatf(angle: radians(rotation.x), axis: [1, 0, 0])
    }

    private static func backgroundColor(_ background: DeviceRenderBackground) -> CGColor {
        switch background {
        case .transparent:
            return CGColor(red: 0, green: 0, blue: 0, alpha: 0)
        case .color(let hex):
            let color = HexColor(hex)
            return CGColor(
                red: color.red,
                green: color.green,
                blue: color.blue,
                alpha: 1
            )
        }
    }

    private static func radians(_ degrees: Double) -> Float {
        Float(degrees * .pi / 180)
    }

    private static func onMain<T>(_ body: @MainActor () throws -> T) throws -> T {
        nonisolated(unsafe) var outcome: Result<T, any Error>?
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                outcome = Result { try body() }
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    outcome = Result { try body() }
                }
            }
        }
        return try outcome!.get()
    }

    private static func onMain(_ body: @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated(body)
            }
        }
    }
}

private extension Entity {
    /// `Entity.load` is warning-gated in async contexts; this adapter is
    /// deliberately synchronous on the main queue.
    @MainActor
    static func loadSynchronously(contentsOf url: URL) throws -> Entity {
        try Entity.load(contentsOf: url)
    }
}
