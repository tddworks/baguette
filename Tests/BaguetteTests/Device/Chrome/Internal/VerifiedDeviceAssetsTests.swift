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
// DeviceKit's plug-in — is read in place from the selected Xcode, or from
// another installed Xcode when the selected one predates it.
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
            xcodes: { [contents.deletingLastPathComponent()] }
        )

        #expect(try assets.resolve(Self.model(directory: scratch, xcodeResource: resource)) == asset)
    }

    /// Xcode 27.0 has no iPhone Duo model; 27.1 and 27.2 ship it. A Mac
    /// that builds with 27.0 selected still renders a Duo from the newer
    /// Xcode beside it — the same file, never a look-alike.
    @Test func `should find an Xcode asset in another installed Xcode when the selected one lacks it`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let resource = "SharedFrameworks/DeviceKit.framework/Resources/V68.usdz"
        let selected = scratch.appending(path: "Xcode-27.0.app")
        let newer = scratch.appending(path: "Xcode-27.2.app")
        let asset = try Self.place(resource, in: newer)
        let assets = VerifiedDeviceAssets(
            cacheRoot: scratch.appending(path: "cache"), fetch: { _ in Data() },
            xcodes: { [selected, newer] })

        #expect(try assets.resolve(Self.model(directory: scratch, xcodeResource: resource)) == asset)
    }

    @Test func `should take the selected Xcode's copy when several Xcodes have the asset`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let resource = "SharedFrameworks/DeviceKit.framework/Resources/V68.usdz"
        let selected = scratch.appending(path: "Xcode-27.1.app")
        let other = scratch.appending(path: "Xcode-27.2.app")
        let chosen = try Self.place(resource, in: selected)
        _ = try Self.place(resource, in: other)
        let assets = VerifiedDeviceAssets(
            cacheRoot: scratch.appending(path: "cache"), fetch: { _ in Data() },
            xcodes: { [selected, other] })

        #expect(try assets.resolve(Self.model(directory: scratch, xcodeResource: resource)) == chosen)
    }

    private static func place(_ resource: String, in xcode: URL) throws -> URL {
        let asset = xcode.appending(path: "Contents").appending(path: resource)
        try FileManager.default.createDirectory(
            at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("USDZ".utf8).write(to: asset)
        return asset
    }

    @Test func `should name the resource and every Xcode it looked in when no Xcode has the asset`() throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let selected = scratch.appending(path: "Xcode-27.0.app")
        let other = scratch.appending(path: "Xcode-26.4.app")
        let assets = VerifiedDeviceAssets(
            cacheRoot: scratch.appending(path: "cache"),
            fetch: { _ in Data() },
            xcodes: { [selected, other] }
        )

        #expect(throws: DeviceModelError.xcodeResourceNotFound(
            "Plugins/V68.usdz", searched: [selected.path, other.path])) {
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
