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
    /// One screen of the model: the mesh and material slot the simulator
    /// frames land on, and the streaming texture sized to those frames.
    private struct ScreenSlot {
        let entity: ModelEntity
        let materialIndex: Int
        let textureSize: RenderDimensions
        var texture: LowLevelTexture?
        var sourceSize: RenderDimensions?
        var contentRegion: ContentRegion?
    }
    private var screen: ScreenSlot!
    /// A foldable's cover, on the far side of the leaf that folds over.
    private var coverScreen: ScreenSlot?
    /// Between the wrapper (the requested rotation) and the model: the
    /// authored rest rotation, and a foldable's centring turn.
    private var rest: Entity!
    private var restOrientation = simd_quatf(angle: 0, axis: [0, 1, 0])
    private var foldController: AnimationPlaybackController?
    private var screenLocalCorners: ScreenLocalCorners!
    private var coverLocalCorners: ScreenLocalCorners?
    private var hingeDegrees: Double = 180
    private var view = Device3DCamera(rotation: .zero, zoom: 1)
    /// The interface orientation the page last asked the guest for; nil
    /// means the usual: the unfolded panel landscape-left, the cover
    /// portrait. Not read back from the guest — the page's rotate
    /// button turns the book, as it turns a phone's chrome.
    private var interfaceOrientation: DeviceOrientation?
    private(set) var screenQuad: ScreenQuad?
    private(set) var screenPieces: [ScreenPiece]?
    private var buttonAnchors: [ScreenButtonAnchor] = []
    private var bodyExtents = Vector3(x: 0, y: 0, z: 0)
    private(set) var screenButtons: [ScreenButtonMark]?
    var litPanel: IntegratedPanel? {
        plan.model.definition.scene.fold == nil ? nil : HingeAngle(degrees: hingeDegrees).litPanel
    }
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
        try renderFrame(screen: surface).surface
    }

    func render(screens: FoldableScreens) throws -> IOSurface {
        try renderFrame(screens: screens).surface
    }

    func renderFrame(screen surface: IOSurface) throws -> DeviceFrame {
        try Self.onMain {
            try self.paint(&self.screen, with: surface)
            return try self.captureFrame()
        }
    }

    func renderFrame(screens: FoldableScreens) throws -> DeviceFrame {
        try Self.onMain {
            if let surface = screens.unfolded { try self.paint(&self.screen, with: surface) }
            if let surface = screens.cover, self.coverScreen != nil {
                try self.paint(&self.coverScreen!, with: surface)
            }
            return try self.captureFrame()
        }
    }

    @MainActor
    private func captureFrame() throws -> DeviceFrame {
        let surface = try renderScene()
        let slot = litPanel == .primary ? coverScreen : screen
        guard let slot, let size = slot.sourceSize,
            screenPieces != nil || screenQuad != nil
        else {
            return DeviceFrame(surface: surface, placement: nil)
        }
        return DeviceFrame(
            surface: surface,
            placement: DeviceFramePlacement(
                quad: screenQuad, pieces: screenPieces, buttons: screenButtons ?? [],
                litPanel: litPanel, hingeDegrees: litPanel == nil ? nil : hingeDegrees,
                sourcePixelSize: size,
                textureTransform: plan.fit.placement(source: size, target: slot.textureSize)
            ))
    }

    /// Pose the book: the shutting clip at the angle's time, the whole
    /// device turned back to centre the bend (`FoldPose`).
    func update(hingeDegrees: Double) {
        Self.onMain {
            guard let fold = self.plan.model.definition.scene.fold,
                  let controller = self.foldController else { return }
            let pose = FoldPose.at(degrees: hingeDegrees, fold: fold)
            controller.time = pose.clipTime
            controller.pause()
            self.rest.orientation = simd_quatf(
                angle: Self.radians(pose.yawDegrees), axis: [0, 1, 0]
            ) * self.restOrientation
            // Keep the book in the middle as it folds, as Device Hub does.
            let shift = self.centring(at: hingeDegrees)
            self.rest.position = SIMD3<Float>(Float(shift.x), Float(shift.y), Float(shift.z))
            self.hingeDegrees = hingeDegrees
            self.wrapper.orientation = Self.orientation(self.effectiveRotation)
            self.screenPieces = self.projectedScreenPieces()
            self.screenButtons = self.projectedScreenButtons()
        }
    }

    func update(camera requested: Device3DCamera) {
        Self.onMain {
            self.view = requested
            if let orientation = requested.orientation { self.interfaceOrientation = orientation }
            self.wrapper.orientation = Self.orientation(self.effectiveRotation)
            self.cameraEntity.position.z = Float(
                self.cameraFraming.distance(at: requested.zoom)
            )
            self.screenQuad = self.projectedScreenQuad(
                rotation: self.effectiveRotation,
                zoom: requested.zoom
            )
            self.screenPieces = self.projectedScreenPieces()
            self.screenButtons = self.projectedScreenButtons()
        }
    }

    /// The requested rotation with a foldable's interface roll on top:
    /// the book stands the way the guest is held (`InterfaceRoll`).
    @MainActor
    private var effectiveRotation: DeviceRotation {
        guard plan.model.definition.scene.fold != nil, let lit = litPanel else { return view.rotation }
        let orientation = interfaceOrientation ?? (lit == .secondary ? .landscapeLeft : .portrait)
        let roll = InterfaceRoll.degrees(orientation, litPanel: lit)
        return DeviceRotation(x: view.rotation.x, y: view.rotation.y, z: view.rotation.z + roll)
    }

    @MainActor
    private func centring(at degrees: Double) -> Vector3 {
        guard let fold = plan.model.definition.scene.fold, let corners = screenLocalCorners else {
            return Vector3(x: 0, y: 0, z: 0)
        }
        return FoldPose.centring(inner: corners, hingeDegrees: degrees, fold: fold)
    }

    @MainActor
    private func projectedScreenButtons() -> [ScreenButtonMark]? {
        guard let fold = plan.model.definition.scene.fold, !buttonAnchors.isEmpty else { return nil }
        return FoldedScreenProjection.buttons(
            buttonAnchors,
            body: bodyExtents,
            margin: max(bodyExtents.x, bodyExtents.y) * 0.06,
            hingeDegrees: hingeDegrees,
            fold: fold,
            rotation: effectiveRotation,
            offset: centring(at: hingeDegrees),
            distance: cameraFraming.distance(at: view.zoom),
            fieldOfViewDegrees: cameraFraming.fieldOfViewDegrees,
            aspect: Double(plan.outputSize.width) / Double(plan.outputSize.height)
        )
    }

    /// A foldable's lit screen in the output image at the current hinge
    /// angle and camera. The unfolded panel's buffer lies landscape-left
    /// on its mesh and the cover's portrait.
    @MainActor
    private func projectedScreenPieces() -> [ScreenPiece]? {
        guard let fold = plan.model.definition.scene.fold,
              let coverLocalCorners else { return nil }
        let lit = HingeAngle(degrees: hingeDegrees).litPanel
        return FoldedScreenProjection.pieces(
            inner: screenLocalCorners,
            cover: coverLocalCorners,
            litPanel: lit,
            // How the panel's buffer lies on the mesh — fixed by the
            // hardware, not by what the guest draws: touches land in
            // buffer space whatever the interface orientation.
            orientation: lit == .secondary ? .landscapeLeft : .portrait,
            hingeDegrees: hingeDegrees,
            fold: fold,
            rotation: effectiveRotation,
            offset: centring(at: hingeDegrees),
            distance: cameraFraming.distance(at: view.zoom),
            fieldOfViewDegrees: cameraFraming.fieldOfViewDegrees,
            aspect: Double(plan.outputSize.width) / Double(plan.outputSize.height)
        )
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
        self.screen = ScreenSlot(
            entity: screen,
            materialIndex: screen.model?.materials.firstIndex {
                $0.name == definition.scene.screenMaterial
            } ?? 0,
            textureSize: definition.scene.textureSize
        )
        try Self.turnTextureCoordinates(
            of: screen, materialIndex: self.screen.materialIndex,
            by: definition.scene.textureRotation ?? 0
        )
        if let fold = definition.scene.fold {
            guard let cover = Self.findScreenEntity(
                under: subject, explicitName: nil, materialName: fold.coverMaterial
            ) else {
                throw DeviceModelError.sceneNodeNotFound(fold.coverMaterial)
            }
            coverScreen = ScreenSlot(
                entity: cover,
                materialIndex: cover.model?.materials.firstIndex {
                    $0.name == fold.coverMaterial
                } ?? 0,
                textureSize: fold.coverTextureSize
            )
            try Self.turnTextureCoordinates(
                of: cover, materialIndex: coverScreen!.materialIndex,
                by: fold.coverTextureRotation ?? 0
            )
            guard let clip = subject.availableAnimations.first(where: {
                $0.name == fold.clip && $0.definition.duration.isFinite
            }) else {
                throw DeviceModelError.sceneNodeNotFound(fold.clip)
            }
            foldController = subject.playAnimation(clip, transitionDuration: 0, startsPaused: true)
        }
        if plan.rendersScreenGlass {
            try Self.addCoverGlass(over: screen, subject: subject)
        }

        let stage = try RealityRenderer()
        renderer = stage
        let wrapperEntity = Entity()
        wrapperEntity.name = "baguette-device"
        let restEntity = Entity()
        restEntity.name = "baguette-rest"
        subject.removeFromParent()
        restEntity.addChild(subject)
        wrapperEntity.addChild(restEntity)
        stage.entities.append(wrapperEntity)
        wrapper = wrapperEntity
        rest = restEntity
        restOrientation = Self.orientation(definition.scene.restRotation ?? .zero)
        restEntity.orientation = restOrientation

        let bounds = subject.visualBounds(relativeTo: wrapperEntity)
        let extents = bounds.extents
        guard extents.x > 0 || extents.y > 0 || extents.z > 0 else {
            throw DeviceModelError.sceneHasNoGeometry
        }
        subject.position -= subject.visualBounds(relativeTo: restEntity).center
        wrapperEntity.orientation = Self.orientation(plan.rotation)

        // Corners in the rest frame: relative to the wrapper, so the
        // authored rest rotation is in and the requested one is not.
        // From the screen's own mesh parts — a model may keep every
        // material on one entity, whose bounds are the whole device.
        let corners = { (slot: ScreenSlot) -> ScreenLocalCorners in
            let bounds = Self.partBounds(of: slot.entity, materialIndex: slot.materialIndex, relativeTo: wrapperEntity)
                ?? slot.entity.visualBounds(relativeTo: wrapperEntity)
            return ScreenLocalCorners.from(
                center: Vector3(
                    x: Double(bounds.center.x),
                    y: Double(bounds.center.y),
                    z: Double(bounds.center.z)
                ),
                extents: Vector3(
                    x: Double(bounds.extents.x),
                    y: Double(bounds.extents.y),
                    z: Double(bounds.extents.z)
                )
            )
        }
        screenLocalCorners = corners(self.screen)
        coverLocalCorners = coverScreen.map(corners)
        bodyExtents = Vector3(x: Double(extents.x), y: Double(extents.y), z: Double(extents.z))
        buttonAnchors = (definition.scene.buttons ?? []).compactMap { button in
            Self.jointRestPosition(named: button.joint, of: self.screen.entity, relativeTo: wrapperEntity)
                .map { ScreenButtonAnchor(id: button.id, at: $0) }
        }

        // A book's leaf stands up toward the camera as it shuts, so a
        // foldable is framed as deep as a leaf is wide.
        let depth = definition.scene.fold == nil
            ? Double(extents.z)
            : max(Double(extents.z), Double(extents.x) / 2)
        let framing = DeviceCameraFraming.fit(
            subjectWidth: Double(extents.x),
            subjectHeight: Double(extents.y),
            subjectDepth: depth,
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

        view = Device3DCamera(rotation: plan.rotation, zoom: 1)
        wrapperEntity.orientation = Self.orientation(effectiveRotation)
        screenQuad = projectedScreenQuad(rotation: effectiveRotation, zoom: 1)
        screenPieces = projectedScreenPieces()
        screenButtons = projectedScreenButtons()

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
    private func paint(_ slot: inout ScreenSlot, with surface: IOSurface) throws {
        let sourceSize = RenderDimensions(
            width: IOSurfaceGetWidth(surface),
            height: IOSurfaceGetHeight(surface)
        )
        let texture = try screenLowLevelTexture(for: sourceSize, on: &slot)
        try blit(surface, into: texture, size: sourceSize, region: slot.contentRegion)
    }

    @MainActor
    private func renderScene() throws -> IOSurface {
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
        for sourceSize: RenderDimensions,
        on slot: inout ScreenSlot
    ) throws -> LowLevelTexture {
        if let texture = slot.texture, slot.sourceSize == sourceSize {
            return texture
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
            target: slot.textureSize
        )
        material.textureCoordinateTransform = .init(
            offset: [Float(placement.offsetX), Float(placement.offsetY)],
            scale: [Float(placement.scaleX), Float(placement.scaleY)]
        )
        if var model = slot.entity.model {
            var materials = model.materials
            materials[slot.materialIndex] = material
            model.materials = materials
            slot.entity.model = model
        }
        // The visible window keeps a permanent 2-pixel black border, and
        // per-frame blits cover only the interior. Texture filtering fades
        // content into the border over a texel, so the display's content
        // edge resolves smoothly instead of dot-dashing at the mesh edge.
        try blackFill(texture, size: sourceSize)
        slot.contentRegion = placement.contentRegion(in: sourceSize, inset: 2)
        slot.texture = texture
        slot.sourceSize = sourceSize
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
        size: RenderDimensions,
        region: ContentRegion?
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
        if let region, region.width > 0, region.height > 0 {
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

    /// A skeleton joint's rest position — the rest pose accumulated up
    /// its parents — in `reference`'s frame; nil when no skeleton of the
    /// entity's mesh has the joint.
    @MainActor
    private static func jointRestPosition(
        named name: String, of entity: ModelEntity, relativeTo reference: Entity
    ) -> Vector3? {
        guard let model = entity.model else { return nil }
        for skeleton in model.mesh.contents.skeletons {
            let joints = skeleton.joints
            guard let index = joints.firstIndex(where: { $0.name == name || $0.name.hasSuffix("/" + name) }) else {
                continue
            }
            var matrix = matrix_identity_float4x4
            var current: Int? = index
            while let i = current {
                matrix = joints[i].restPoseTransform.matrix * matrix
                current = joints[i].parentIndex
            }
            let local = SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
            let world = entity.convert(position: local, to: reference)
            return Vector3(x: Double(world.x), y: Double(world.y), z: Double(world.z))
        }
        return nil
    }

    /// The bounds of the mesh parts on one material, in `reference`'s
    /// frame; nil when the entity has no such part.
    @MainActor
    private static func partBounds(
        of entity: ModelEntity, materialIndex: Int, relativeTo reference: Entity
    ) -> BoundingBox? {
        guard let model = entity.model else { return nil }
        var box: BoundingBox?
        for mesh in model.mesh.contents.models {
            for part in mesh.parts where part.materialIndex == materialIndex {
                for position in part.positions.elements {
                    let world = entity.convert(position: position, to: reference)
                    if var current = box {
                        current.formUnion(BoundingBox(min: world, max: world))
                        box = current
                    } else {
                        box = BoundingBox(min: world, max: world)
                    }
                }
            }
        }
        return box
    }

    /// Turn a screen's texture coordinates by quarter turns, so frames
    /// whose rows run the other way from the mesh's UVs read upright.
    /// Rewrites only the parts on that material; skinning and the rest
    /// of the mesh round-trip untouched.
    @MainActor
    private static func turnTextureCoordinates(
        of entity: ModelEntity, materialIndex: Int, by degrees: Int
    ) throws {
        let turns = (((degrees / 90) % 4) + 4) % 4
        guard turns != 0, var model = entity.model else { return }
        var contents = model.mesh.contents
        contents.models = .init(contents.models.map { mesh in
            var mesh = mesh
            mesh.parts = .init(mesh.parts.map { part in
                guard part.materialIndex == materialIndex,
                      let coordinates = part.textureCoordinates else { return part }
                var part = part
                part.textureCoordinates = .init(coordinates.elements.map { point in
                    var u = point.x, v = point.y
                    for _ in 0..<turns { (u, v) = (v, 1 - u) }
                    return SIMD2<Float>(u, v)
                })
                return part
            })
            return mesh
        })
        try model.mesh.replace(with: contents)
        entity.model = model
    }

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
