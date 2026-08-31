import Foundation

/// Loads installed model bundles from ordered filesystem roots.
///
/// Each root is one precedence layer. A model bundle is an immediate
/// child directory containing `definition.json`; unrelated files and
/// incomplete directories are ignored.
struct LiveDeviceModels: DeviceModels, Sendable {
    private let catalog: DeviceModelCatalog

    init(rootURLs: [URL], fileManager: FileManager = .default) throws {
        let layers = try rootURLs.map { root in
            try Self.loadLayer(at: root, fileManager: fileManager)
        }
        catalog = try DeviceModelCatalog(layers: layers)
    }

    func find(id: DeviceModelID) throws -> InstalledDeviceModel? {
        catalog.find(id: id)
    }

    func match(deviceType: String, deviceName: String) throws -> InstalledDeviceModel? {
        try catalog.match(deviceType: deviceType, deviceName: deviceName)
    }

    func match(hardware: String) throws -> InstalledDeviceModel? {
        try catalog.match(hardware: hardware)
    }

    func all() throws -> [InstalledDeviceModel] {
        catalog.all()
    }

    private static func loadLayer(
        at root: URL,
        fileManager: FileManager
    ) throws -> [InstalledDeviceModel] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return try entries
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { directory in
                let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { return nil }

                let definitionURL = directory.appending(path: "definition.json")
                guard fileManager.fileExists(atPath: definitionURL.path) else { return nil }

                do {
                    let json = try Data(contentsOf: definitionURL)
                    let definition = try DeviceModelDefinition.parsing(json: json)
                    return InstalledDeviceModel(
                        definition: definition,
                        directoryURL: directory
                    )
                } catch {
                    throw DeviceModelError.malformedDefinition(definitionURL.path)
                }
            }
    }
}
