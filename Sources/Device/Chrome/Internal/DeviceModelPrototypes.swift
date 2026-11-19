import Foundation
import RealityKit

/// The device models loaded into RealityKit, one prototype each, that
/// every live 3D scene clones its device from.
///
/// RealityKit keeps the assets of every `Entity.load` for the life of
/// the process — loading the same file again does not share them — so a
/// model loaded per stream grew the server with every connection. A
/// clone shares the prototype's meshes and textures and costs nothing
/// that outlives it. A prototype is keyed by everything that shapes it:
/// the asset, its USD variants, and the scene definition whose screen
/// texture turns are baked into the shared meshes.
///
/// Main-thread only, like the RealityKit entities it holds.
public final class DeviceModelPrototypes: @unchecked Sendable {
    public struct Key: Equatable {
        public let asset: URL
        public let variants: [DeviceVariantSelection]
        public let scene: DeviceModelScene

        public init(asset: URL, variants: [DeviceVariantSelection], scene: DeviceModelScene) {
            self.asset = asset
            self.variants = variants
            self.scene = scene
        }
    }

    public static let shared = DeviceModelPrototypes()

    private let lock = NSLock()
    private var prototypes: [(key: Key, entity: Entity)] = []

    /// How many models have been loaded.
    public var count: Int { lock.withLock { prototypes.count } }

    /// A fresh clone of the model `key` names, loading it with `load` the
    /// first time. A failed load is not remembered.
    @MainActor
    public func instance(of key: Key, load: () throws -> Entity) throws -> Entity {
        if let prototype = lock.withLock({ prototypes.first { $0.key == key }?.entity }) {
            return prototype.clone(recursive: true)
        }
        let prototype = try load()
        lock.withLock { prototypes.append((key, prototype)) }
        return prototype.clone(recursive: true)
    }
}
