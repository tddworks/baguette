import Foundation
import Testing

@testable import Baguette
@testable import BaguetteDevice

@Suite("ScreenshotMetadata")
struct ScreenshotMetadataTests {
    @Test func `should write metadata separately from the exact captured image bytes`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("frame.png")
        let metadata = directory.appendingPathComponent("frame.json")
        let command = try ScreenshotCommand.parse([
            "--udid", "test", "--output", image.path, "--metadata-output", metadata.path,
        ])
        let frame = ScreenSnapshot.Frame(
            bytes: Data([1, 2, 3]),
            geometry: CaptureGeometry(
                framebufferPixels: RenderDimensions(width: 120, height: 60),
                scaledPixels: RenderDimensions(width: 60, height: 30),
                placement: CapturePlacement(width: 40, height: 80, drawX: 0, drawY: 30, drawWidth: 40, drawHeight: 20)
            )
        )

        try command.write(frame)

        #expect(try Data(contentsOf: image) == frame.bytes)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        #expect(json["framebufferPixels"] as? [String: Int] == ["width": 120, "height": 60])
        #expect(json["scaledPixels"] as? [String: Int] == ["width": 60, "height": 30])
        #expect(json["imagePixels"] as? [String: Int] == ["width": 40, "height": 80])
        #expect(json["drawRectPixels"] as? [String: Int] == ["x": 0, "y": 30, "width": 40, "height": 20])
    }

    @Test func `should keep the image on stdout by default when writing a metadata sidecar`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("frame.png")
        let metadata = directory.appendingPathComponent("frame.json")
        try Data().write(to: image)
        let stdout = try FileHandle(forWritingTo: image)
        defer { try? stdout.close() }
        let command = try ScreenshotCommand.parse(["--udid", "test", "--metadata-output", metadata.path])

        try command.write(frame, stdout: stdout)

        #expect(try Data(contentsOf: image) == frame.bytes)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        #expect(json["imagePixels"] as? [String: Int] == ["width": 20, "height": 10])
    }

    @Test(arguments: ["same", "symlink", "hardlink"])
    func `should refuse to let metadata overwrite redirected stdout`(alias: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("frame.png")
        let metadata = alias == "same" ? image : directory.appendingPathComponent("frame.json")
        let original = Data([9, 8, 7])
        try original.write(to: image)
        if alias == "symlink" {
            try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: image)
        } else if alias == "hardlink" {
            try FileManager.default.linkItem(at: image, to: metadata)
        }
        let stdout = try FileHandle(forWritingTo: image)
        defer { try? stdout.close() }
        let command = try ScreenshotCommand.parse(["--udid", "test", "--metadata-output", metadata.path])

        #expect(throws: (any Error).self) { try command.write(frame, stdout: stdout) }
        #expect(try Data(contentsOf: image) == original)
        #expect(try Data(contentsOf: metadata) == original)
    }

    @Test func `should reject an image and metadata at the same normalized path`() {
        #expect(throws: (any Error).self) {
            try ScreenshotCommand.parse([
                "--udid", "test", "--output", "/tmp/frame.png",
                "--metadata-output", "/tmp/./frame.png",
            ])
        }
    }

    @Test(arguments: [false, true])
    func `should reject an image and metadata that alias one existing file`(hardLink: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("frame.png")
        let metadata = directory.appendingPathComponent("frame.json")
        try Data([1, 2, 3]).write(to: image)
        if hardLink {
            try FileManager.default.linkItem(at: image, to: metadata)
        } else {
            try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: image)
        }

        #expect(throws: (any Error).self) {
            try ScreenshotCommand.parse([
                "--udid", "test", "--output", image.path, "--metadata-output", metadata.path,
            ])
        }
        #expect(try Data(contentsOf: image) == Data([1, 2, 3]))
    }

    private var frame: ScreenSnapshot.Frame {
        ScreenSnapshot.Frame(
            bytes: Data([1, 2, 3]),
            geometry: CaptureGeometry(
                framebufferPixels: RenderDimensions(width: 20, height: 10),
                scaledPixels: RenderDimensions(width: 20, height: 10),
                placement: CapturePlacement(width: 20, height: 10, drawX: 0, drawY: 0, drawWidth: 20, drawHeight: 10)
            )
        )
    }
}
