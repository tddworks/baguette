import CryptoKit
import Foundation

/// Resolves a model's local USD asset or installs its verified download
/// into the application-support cache. Network fetch is the irreducible
/// one-shot I/O; hash verification and cache transitions are exercised
/// with an injected fetch closure.
struct VerifiedDeviceAssets: @unchecked Sendable {
    typealias Fetch = (URL) throws -> Data

    private let cacheRoot: URL
    private let fetch: Fetch
    private let developerDir: () -> String

    init(
        cacheRoot: URL = Self.defaultCacheRoot,
        fetch: @escaping Fetch = { try Data(contentsOf: $0) },
        developerDir: @escaping () -> String = { CoreSimulators.developerDir() }
    ) {
        self.cacheRoot = cacheRoot
        self.fetch = fetch
        self.developerDir = developerDir
    }

    func resolve(_ model: InstalledDeviceModel) throws -> URL {
        // An asset Apple ships inside Xcode: `<Xcode>/Contents/<resource>`,
        // the developer dir being `<Xcode>/Contents/Developer`.
        if let resource = model.definition.asset.xcodeResource, !resource.isEmpty {
            let contents = URL(fileURLWithPath: developerDir()).deletingLastPathComponent()
            let candidate = contents.appending(path: resource)
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                throw DeviceModelError.localAssetNotFound(resource)
            }
            return candidate
        }
        if model.definition.asset.file != nil {
            do {
                return try model.localAssetURL()
            } catch DeviceModelError.localAssetNotFound(let file) {
                guard model.definition.asset.downloadURL != nil else {
                    throw DeviceModelError.localAssetNotFound(file)
                }
            }
        }

        guard let rawURL = model.definition.asset.downloadURL,
              let sourceURL = URL(string: rawURL),
              let expectedHash = model.definition.asset.sha256?.lowercased() else {
            throw DeviceModelError.invalidDownloadURL(
                model.definition.asset.downloadURL ?? ""
            )
        }
        let extensionName = sourceURL.pathExtension.isEmpty
            ? "usdz"
            : sourceURL.pathExtension
        let modelCache = cacheRoot.appending(path: model.definition.id.rawValue)
        let destination = modelCache.appending(path: "device.\(extensionName)")

        if let cached = try? Data(contentsOf: destination),
           Self.sha256(cached) == expectedHash {
            return destination
        }

        let downloaded: Data
        do {
            downloaded = try fetch(sourceURL)
        } catch {
            throw DeviceModelError.assetDownloadFailed(rawURL)
        }
        guard Self.sha256(downloaded) == expectedHash else {
            throw DeviceModelError.assetHashMismatch
        }
        do {
            try FileManager.default.createDirectory(
                at: modelCache,
                withIntermediateDirectories: true
            )
            try downloaded.write(to: destination, options: .atomic)
        } catch {
            throw DeviceModelError.assetCacheWriteFailed(destination.path)
        }
        return destination
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static var defaultCacheRoot: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support
            .appending(path: "com.tddworks.baguette")
            .appending(path: "3d-asset-cache")
    }
}
