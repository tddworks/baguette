import Foundation
import Mockable

struct InstalledDeviceModel: Equatable, Sendable {
    let definition: DeviceModelDefinition
    let directoryURL: URL

    func localAssetURL(fileManager: FileManager = .default) throws -> URL {
        guard let file = definition.asset.file, !file.isEmpty else {
            throw DeviceModelError.localAssetNotFound("")
        }
        guard !(file as NSString).isAbsolutePath else {
            throw DeviceModelError.assetOutsideBundle(file)
        }

        let candidate = directoryURL.appending(path: file)
        let rootPath = directoryURL.resolvingSymlinksInPath().standardizedFileURL.path
        let targetPath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        guard targetPath.hasPrefix(rootPath + "/") else {
            throw DeviceModelError.assetOutsideBundle(file)
        }
        guard fileManager.fileExists(atPath: candidate.path) else {
            throw DeviceModelError.localAssetNotFound(file)
        }
        return candidate
    }
}

@Mockable
protocol DeviceModels: Sendable {
    func find(id: DeviceModelID) throws -> InstalledDeviceModel?
    func match(deviceType: String, deviceName: String) throws -> InstalledDeviceModel?
    /// Match a physical device by hardware identifier ("iPhone14,3").
    func match(hardware: String) throws -> InstalledDeviceModel?
    /// Every installed model, higher precedence layers shadowing lower
    /// ones by id — the choices offered when no definition matches a
    /// physical device and the user picks one explicitly.
    func all() throws -> [InstalledDeviceModel]
}

struct DeviceModelCatalog: DeviceModels, Equatable, Sendable {
    static let empty = try! DeviceModelCatalog(layers: [])

    private let layers: [[InstalledDeviceModel]]

    init(layers: [[InstalledDeviceModel]]) throws {
        for layer in layers {
            var ids = Set<DeviceModelID>()
            for model in layer {
                guard ids.insert(model.definition.id).inserted else {
                    throw DeviceModelError.duplicateModelID(model.definition.id.rawValue)
                }
            }
        }
        self.layers = layers
    }

    func find(id: DeviceModelID) -> InstalledDeviceModel? {
        for layer in layers {
            if let model = layer.first(where: { $0.definition.id == id }) {
                return model
            }
        }
        return nil
    }

    func match(deviceType: String, deviceName: String) throws -> InstalledDeviceModel? {
        for layer in layers {
            let matches = layer.filter {
                $0.definition.matches(deviceType: deviceType, deviceName: deviceName)
            }
            if matches.count > 1 {
                throw DeviceModelError.ambiguousMatch(
                    matches.map { $0.definition.id.rawValue }.sorted()
                )
            }
            if let match = matches.first {
                return match
            }
        }
        return nil
    }

    func match(hardware: String) throws -> InstalledDeviceModel? {
        for layer in layers {
            let matches = layer.filter { $0.definition.matches(hardware: hardware) }
            if matches.count > 1 {
                throw DeviceModelError.ambiguousMatch(
                    matches.map { $0.definition.id.rawValue }.sorted()
                )
            }
            if let match = matches.first {
                return match
            }
        }
        return nil
    }

    func all() -> [InstalledDeviceModel] {
        var seen = Set<DeviceModelID>()
        var models: [InstalledDeviceModel] = []
        for layer in layers {
            for model in layer where seen.insert(model.definition.id).inserted {
                models.append(model)
            }
        }
        return models
    }
}
