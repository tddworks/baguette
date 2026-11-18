import CryptoKit
import Foundation
import Testing
@testable import Baguette
@testable import BaguetteDevice

@Suite("VerifiedDeviceAssets")
struct VerifiedDeviceAssetsTests {

    @Test func `should use an existing local asset without downloading`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bundle = scratch.appending(path: "bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let local = bundle.appending(path: "device.usdz")
        try Data("LOCAL".utf8).write(to: local)
        let model = Self.model(directory: bundle, file: "device.usdz")
        var downloads = 0
        let assets = VerifiedDeviceAssets(
            cacheRoot: scratch.appending(path: "cache"),
            fetch: { _ in downloads += 1; return Data("REMOTE".utf8) }
        )

        #expect(try assets.resolve(model) == local)
        #expect(downloads == 0)
    }

    @Test func `should cache a verified download atomically`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bytes = Data("VERIFIED-USDZ".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let model = Self.model(
            directory: scratch.appending(path: "bundle"),
            file: "device.usdz",
            downloadURL: "https://example.com/device.usdz",
            sha256: hash
        )
        var downloads = 0
        let assets = VerifiedDeviceAssets(
            cacheRoot: scratch.appending(path: "cache"),
            fetch: { _ in downloads += 1; return bytes }
        )

        let resolved = try assets.resolve(model)

        #expect(try Data(contentsOf: resolved) == bytes)
        #expect(downloads == 1)
        #expect(try assets.resolve(model) == resolved)
        #expect(downloads == 1)
    }

    @Test func `should never install downloaded bytes whose hash mismatches`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let expected = String(repeating: "0", count: 64)
        let model = Self.model(
            directory: scratch.appending(path: "bundle"),
            file: nil,
            downloadURL: "https://example.com/device.usdz",
            sha256: expected
        )
        let assets = VerifiedDeviceAssets(
            cacheRoot: scratch.appending(path: "cache"),
            fetch: { _ in Data("TAMPERED".utf8) }
        )

        #expect(throws: DeviceModelError.assetHashMismatch) {
            _ = try assets.resolve(model)
        }
        #expect(FileManager.default.fileExists(
            atPath: scratch.appending(path: "cache/test-device/device.usdz").path
        ) == false)
    }
}

private extension VerifiedDeviceAssetsTests {
    static func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "baguette-assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func model(
        directory: URL,
        file: String?,
        downloadURL: String? = nil,
        sha256: String? = nil
    ) -> InstalledDeviceModel {
        InstalledDeviceModel(
            definition: DeviceModelDefinition(
                schemaVersion: 1,
                id: "test-device",
                displayName: "Test",
                matches: DeviceModelMatches(),
                asset: DeviceModelAsset(
                    file: file,
                    downloadURL: downloadURL,
                    sha256: sha256
                ),
                scene: DeviceModelScene(
                    rootNode: "Device",
                    screenNode: "Screen",
                    screenMaterial: "Screen",
                    nativeOrientation: .portrait,
                    textureSize: RenderDimensions(width: 100, height: 200),
                    usesScreenOverlay: false
                ),
                variantSets: []
            ),
            directoryURL: directory
        )
    }
}

// An asset Apple ships inside Xcode — iPhone Duo's `V68.usdz` in
// DeviceKit's plug-in — is read from the selected Xcode, the way the 2D
// chromes are read from `/Library/Developer/DeviceKit`.
extension VerifiedDeviceAssetsTests {
    @Test func `should resolve an asset that lives in Xcode under the selected Xcode's Contents`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let contents = scratch.appending(path: "Xcode.app/Contents")
        let resource = "SharedFrameworks/DeviceKit.framework/Resources/V68.usdz"
        let asset = contents.appending(path: resource)
        try FileManager.default.createDirectory(
            at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("USDZ".utf8).write(to: asset)
        let assets = VerifiedDeviceAssets(
            cacheRoot: scratch.appending(path: "cache"),
            fetch: { _ in Data() },
            developerDir: { contents.appending(path: "Developer").path }
        )

        #expect(try assets.resolve(Self.model(directory: scratch, xcodeResource: resource)) == asset)
    }

    @Test func `should name the resource it looked for when an Xcode asset is missing`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let assets = VerifiedDeviceAssets(
            cacheRoot: scratch.appending(path: "cache"),
            fetch: { _ in Data() },
            developerDir: { scratch.appending(path: "Xcode.app/Contents/Developer").path }
        )

        #expect(throws: DeviceModelError.localAssetNotFound("Plugins/V68.usdz")) {
            try assets.resolve(Self.model(directory: scratch, xcodeResource: "Plugins/V68.usdz"))
        }
    }

    static func model(directory: URL, xcodeResource: String) -> InstalledDeviceModel {
        let base = model(directory: directory, file: nil)
        return InstalledDeviceModel(
            definition: DeviceModelDefinition(
                schemaVersion: 1, id: base.definition.id, displayName: base.definition.displayName,
                matches: base.definition.matches,
                asset: DeviceModelAsset(file: nil, downloadURL: nil, sha256: nil, xcodeResource: xcodeResource),
                scene: base.definition.scene, variantSets: []),
            directoryURL: directory)
    }
}
