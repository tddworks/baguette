import Foundation
import IOSurface
import Mockable
import Testing

@testable import Baguette

@Suite("DeviceFrame")
struct DeviceFrameTests {
    @Test func `one packet carries the JPEG and its exact placement`() throws {
        let placement = Self.placement(width: 100)
        let jpeg = Data([0xff, 0xd8, 7, 0xff, 0xd9])
        let packet = try DeviceFrameEnvelope.encode(frameID: 17, placement: placement, jpeg: jpeg)
        let length = packet.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        let json = try #require(
            JSONSerialization.jsonObject(with: packet.subdata(in: 4..<(4 + length))) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        #expect(json["frameId"] as? Int == 17)
        let geometry = try #require(json["placement"] as? [String: Any])
        #expect((geometry["sourcePixelSize"] as? [String: Int]) == ["width": 100, "height": 200])
        #expect((geometry["textureTransform"] as? [String: Double])?["offsetX"] == 0.25)
        #expect(packet.suffix(jpeg.count) == jpeg)
    }

    @Test func `unknown placement stays explicitly null and invalid payloads fail`() throws {
        let packet = try DeviceFrameEnvelope.encode(frameID: 1, placement: nil, jpeg: Data([0xff, 0xd8, 0xff, 0xd9]))
        let length = packet.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        let json = try #require(
            JSONSerialization.jsonObject(with: packet.subdata(in: 4..<(4 + length))) as? [String: Any])
        #expect(json["placement"] is NSNull)
        #expect(throws: (any Error).self) { try DeviceFrameEnvelope.encode(frameID: 0, placement: nil, jpeg: Data()) }
        #expect(throws: (any Error).self) {
            try DeviceFrameEnvelope.encode(
                frameID: 1, placement: nil, jpeg: Data(repeating: 0, count: 16 * 1024 * 1024 + 1))
        }
    }

    @Test func `backpressure drops a metadata packet as a whole instead of preserving its zero prefix`() {
        var backlog = FrameBacklog(byteBudget: 5, preservingDescriptions: false)
        let old = Data([0, 0, 0, 1, 11])
        let recent = Data([0, 0, 0, 1, 33])
        backlog.append(old)
        backlog.append(recent)
        #expect(backlog.count == 1)
        #expect(backlog.popFirst() == recent)
    }

    @Test func `blocked rendering retains matching geometry and drops intermediate pending frames`() throws {
        let source = MockScreen()
        let scene = MockDeviceScene()
        let first = try #require(RenderedScreenTests.surface(width: 2, height: 2))
        let middle = try #require(RenderedScreenTests.surface(width: 3, height: 2))
        let last = try #require(RenderedScreenTests.surface(width: 4, height: 2))
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var sourceDelivery: (@Sendable (IOSurface) -> Void)?
        let received = Frames()
        given(source).start(onFrame: .any).willProduce { sourceDelivery = $0 }
        given(source).stop().willReturn()
        given(scene).renderFrame(screen: .any).willProduce { surface in
            let width = IOSurfaceGetWidth(surface)
            let frame = DeviceFrame(surface: surface, placement: Self.placement(width: width))
            if width == 2 {
                started.signal()
                _ = release.wait(timeout: .now() + 2)
            }
            return frame
        }
        let screen = RenderedScreen(source: source, scene: scene)
        try screen.startFrames { result in received.add(result) }
        defer {
            screen.stop()
            release.signal()
        }
        sourceDelivery?(first)
        #expect(started.wait(timeout: .now() + 1) == .success)
        sourceDelivery?(middle)
        sourceDelivery?(last)
        release.signal()
        #expect(RenderedScreenTests.waitUntil { received.values.count == 2 })
        let frames = try received.values.map { try $0.get() }
        #expect(frames.map { IOSurfaceGetWidth($0.surface) } == [2, 4])
        #expect(frames.map { $0.placement?.sourcePixelSize.width } == [2, 4])
    }

    @Test func `metadata is opt in and duplicate or malformed flags fail`() throws {
        #expect(try !Device3DStreamOptions.parse([:]).frameMetadata)
        #expect(try Device3DStreamOptions.parse(["frameMetadata": ["1"]]).frameMetadata)
        #expect(throws: DeviceModelError.invalidRenderOptions) {
            try Device3DStreamOptions.parse(["frameMetadata": ["maybe"]])
        }
        #expect(throws: DeviceModelError.invalidRenderOptions) {
            try Device3DStreamOptions.parse(["frameMetadata": ["1", "1"]])
        }
    }

    @Test func `foldable snapshots retain the selected panel and source dimensions`() throws {
        let unfolded = MockScreen()
        let cover = MockScreen()
        let hinge = MockHinge()
        let watch = MockHingeWatch()
        let scene = MockDeviceScene()
        let surface = try #require(RenderedScreenTests.surface(width: 3, height: 2))
        var sourceDelivery: (@Sendable (IOSurface) -> Void)?
        let received = Frames()
        given(unfolded).start(onFrame: .any).willReturn()
        given(cover).start(onFrame: .any).willProduce { sourceDelivery = $0 }
        given(unfolded).stop().willReturn()
        given(cover).stop().willReturn()
        given(hinge).angle().willReturn(HingeAngle(degrees: 0))
        given(hinge).watch(onAngle: .any).willReturn(watch)
        given(watch).cancel().willReturn()
        given(scene).update(hingeDegrees: .any).willReturn()
        let placement = DeviceFramePlacement(
            quad: nil, pieces: [], buttons: [], litPanel: .primary, hingeDegrees: 0,
            sourcePixelSize: .init(width: 3, height: 2), textureTransform: .identity
        )
        given(scene).renderFrame(screens: .any).willReturn(DeviceFrame(surface: surface, placement: placement))
        let screen = RenderedFoldable(unfolded: unfolded, cover: cover, hinge: hinge, scene: scene)
        try screen.startFrames { received.add($0) }
        defer { screen.stop() }
        sourceDelivery?(surface)
        #expect(RenderedScreenTests.waitUntil { received.values.count == 1 })
        let frame = try #require(received.values.first).get()
        #expect(frame.placement?.litPanel == .primary)
        #expect(frame.placement?.sourcePixelSize == RenderDimensions(width: 3, height: 2))
    }

    static func placement(width: Int) -> DeviceFramePlacement {
        let quad = ScreenQuad(
            topLeft: .init(u: 0, v: 0), topRight: .init(u: 1, v: 0), bottomRight: .init(u: 1, v: 1),
            bottomLeft: .init(u: 0, v: 1))
        return DeviceFramePlacement(
            quad: quad, pieces: nil, buttons: [], litPanel: nil, hingeDegrees: nil,
            sourcePixelSize: .init(width: width, height: 200),
            textureTransform: .init(scaleX: 0.5, scaleY: 1, offsetX: 0.25, offsetY: 0))
    }
}

private final class Frames: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Result<DeviceFrame, any Error>] = []
    var values: [Result<DeviceFrame, any Error>] { lock.withLock { storage } }
    func add(_ frame: Result<DeviceFrame, any Error>) { lock.withLock { storage.append(frame) } }
}

@Suite("DeviceFrameEncoder")
struct DeviceFrameEncoderTests {
    @Test func `encode failure sends no partial frame and stops later delivery`() throws {
        let state = EncodedFrames()
        let encoder = DeviceFrameEncoder(
            encode: { _ in nil }, deliver: { state.add($0) }, onError: { _ in state.fail() })
        let surface = try #require(RenderedScreenTests.surface(width: 2, height: 2))
        let frame = DeviceFrame(surface: surface, placement: DeviceFrameTests.placement(width: 2))
        encoder.receive(.success(frame))
        encoder.receive(.success(frame))
        #expect(state.packets.isEmpty)
        #expect(state.failures == 1)
    }

    @Test func `stop during encoding discards pixels and metadata together`() throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let state = EncodedFrames()
        let encoder = DeviceFrameEncoder(
            encode: { _ in
                started.signal()
                _ = release.wait(timeout: .now() + 2)
                return Data([0xff, 0xd8, 0xff, 0xd9])
            }, deliver: { state.add($0) }, onError: { _ in state.fail() })
        let surface = try #require(RenderedScreenTests.surface(width: 2, height: 2))
        let frame = DeviceFrame(surface: surface, placement: nil)
        Thread.detachNewThread {
            encoder.receive(.success(frame))
            finished.signal()
        }
        #expect(started.wait(timeout: .now() + 1) == .success)
        encoder.stop()
        release.signal()
        #expect(finished.wait(timeout: .now() + 1) == .success)
        #expect(state.packets.isEmpty)
        #expect(state.failures == 0)
    }

    @Test func `frame numbers advance only with complete packets and rendering failures terminate`() throws {
        let state = EncodedFrames()
        let encoder = DeviceFrameEncoder(
            encode: { _ in Data([0xff, 0xd8, 0xff, 0xd9]) }, deliver: { state.add($0) }, onError: { _ in state.fail() })
        let surface = try #require(RenderedScreenTests.surface(width: 2, height: 2))
        for _ in 0..<2 { encoder.receive(.success(DeviceFrame(surface: surface, placement: nil))) }
        encoder.receive(.failure(DeviceModelError.renderFailed))
        encoder.receive(.success(DeviceFrame(surface: surface, placement: nil)))
        let ids = try state.packets.map { data in
            let length = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            let json = try #require(
                JSONSerialization.jsonObject(with: data.subdata(in: 4..<(4 + length))) as? [String: Any])
            return json["frameId"] as? Int
        }
        #expect(ids == [1, 2])
        #expect(state.failures == 1)
    }
}

private final class EncodedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []
    private var errors = 0
    var packets: [Data] { lock.withLock { storage } }
    var failures: Int { lock.withLock { errors } }
    func add(_ value: Data) { lock.withLock { storage.append(value) } }
    func fail() { lock.withLock { errors += 1 } }
}
