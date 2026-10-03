import CoreVideo
import Foundation
import IOSurface
import Testing

@testable import Baguette

@Suite("DeviceAVCCFrame")
struct DeviceAVCCFrameTests {
    @Test func `codec descriptions are separate from visual frame identities`() throws {
        let description = try DeviceAVCCEnvelope.description(Data([1, 100, 0, 31]))
        let (metadata, body) = try Self.unpack(description)
        #expect(metadata["version"] as? Int == 2)
        #expect(metadata["type"] as? String == "description")
        #expect(metadata["frameId"] == nil)
        #expect(body == Data([1, 1, 100, 0, 31]))
        let frame = try DeviceAVCCEnvelope.frame(
            frameID: 3, placement: DeviceFrameTests.placement(width: 1206),
            tag: AVCCEnvelope.deltaTag, payload: Data([0, 0, 0, 1, 7]))
        let (geometry, video) = try Self.unpack(frame)
        #expect(geometry["frameId"] as? Int == 3)
        #expect(
            (geometry["placement"] as? [String: Any])?["sourcePixelSize"] as? [String: Int]
                == ["width": 1206, "height": 200])
        #expect(video == Data([3, 0, 0, 0, 1, 7]))
    }

    @Test func `invalid identities tags and oversized payloads are rejected`() {
        for (id, tag, data) in [
            (0, UInt8(2), Data([1])), (1, UInt8(1), Data([1])),
            (1, UInt8(3), Data()), (1, UInt8(4), Data([1])),
            (1, UInt8(2), Data(repeating: 1, count: 16 * 1024 * 1024)),
        ] {
            #expect(throws: (any Error).self) {
                try DeviceAVCCEnvelope.frame(frameID: id, placement: nil, tag: tag, payload: data)
            }
        }
    }

    @Test func `slow consumers reject overflow without discarding encoded references`() {
        var backlog = FrameBacklog(byteBudget: 8, preservingDescriptions: false, rejectingOverflow: true)
        let first = backlog.append(Data([1, 2, 3, 4]))
        let second = backlog.append(Data([5, 6, 7, 8]))
        let overflow = backlog.append(Data([9]))
        #expect(first && second)
        #expect(!overflow)
        #expect(backlog.byteCount == 8)
        #expect(backlog.droppedCount == 0)
        #expect(backlog.popFirst() == Data([1, 2, 3, 4]))
        #expect(backlog.popFirst() == Data([5, 6, 7, 8]))
    }

    @Test func `delayed encoding keeps original geometry and replaces only unsubmitted frames`() throws {
        let state = AVCCState()
        let encoder = Self.encoder(state)
        defer { encoder.stop() }
        for width in [2, 4, 6] {
            encoder.receive(
                .success(
                    DeviceFrame(
                        surface: try #require(RenderedScreenTests.surface(width: width, height: 2)),
                        placement: DeviceFrameTests.placement(width: width))))
        }
        #expect(state.widths == [2])
        state.complete(.success(.init(description: Data([1, 100, 0, 31]), kind: .keyframe, avcc: Data([11]))))
        #expect(RenderedScreenTests.waitUntil { state.widths == [2, 6] })
        state.complete(.success(.init(description: nil, kind: .delta, avcc: Data([33]))))
        #expect(RenderedScreenTests.waitUntil { state.packets.count == 4 })
        let unpacked = try state.packets.map(Self.unpack)
        let frames = unpacked.filter { $0.0["type"] as? String == "frame" }
        #expect(frames.map { $0.0["frameId"] as? Int } == [1, 2, 3])
        #expect(
            frames.map { ($0.0["placement"] as? [String: Any])?["sourcePixelSize"] as? [String: Int] }
                == [["width": 2, "height": 200], ["width": 2, "height": 200], ["width": 6, "height": 200]])
        #expect(frames.map { $0.1.first } == [4, 2, 3])
        #expect(frames.last?.1 == Data([3, 33]))
    }

    @Test func `a dropped frame advances pending rendering without closing the stream`() throws {
        let state = AVCCState()
        let encoder = Self.encoder(state)
        defer { encoder.stop() }
        for width in [2, 4] {
            encoder.receive(
                .success(
                    DeviceFrame(
                        surface: try #require(RenderedScreenTests.surface(width: width, height: 2)), placement: nil)))
        }
        state.complete(.success(nil))
        #expect(RenderedScreenTests.waitUntil { state.widths == [2, 4] })
        state.complete(.success(.init(description: Data([1, 100, 0, 31]), kind: .keyframe, avcc: Data([44]))))
        #expect(RenderedScreenTests.waitUntil { state.packets.count == 3 })
        #expect(state.errors == 0)
        let last = try Self.unpack(#require(state.packets.last))
        #expect(last.1 == Data([2, 44]))
    }

    @Test func `failure and stop discard deferred frames and late completions`() throws {
        for fail in [true, false] {
            let state = AVCCState()
            let encoder = Self.encoder(state)
            let surface = try #require(RenderedScreenTests.surface(width: 2, height: 2))
            encoder.receive(.success(DeviceFrame(surface: surface, placement: nil)))
            encoder.receive(.success(DeviceFrame(surface: surface, placement: nil)))
            if fail {
                state.complete(.failure(DeviceModelError.renderFailed))
                #expect(RenderedScreenTests.waitUntil { state.errors == 1 })
            } else {
                encoder.stop()
                state.complete(.success(.init(description: nil, kind: .delta, avcc: Data([1]))))
            }
            encoder.stop()
            #expect(state.packets.count == 1)
            #expect(state.widths == [2])
            #expect(state.errors == (fail ? 1 : 0))
        }
    }

    private static func encoder(_ state: AVCCState) -> DeviceAVCCEncoder {
        DeviceAVCCEncoder(
            copy: { surface in
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(
                    nil, IOSurfaceGetWidth(surface), 2,
                    kCVPixelFormatType_32BGRA, nil, &buffer)
                return buffer
            },
            seed: { _ in Data([0xff, 0xd8, 0xff, 0xd9]) },
            encode: { state.submit($0, completion: $1) },
            deliver: { state.add($0) }, onError: { _ in state.fail() })
    }

    static func unpack(_ data: Data) throws -> ([String: Any], Data) {
        let length = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        let metadata = try #require(
            JSONSerialization.jsonObject(with: data.subdata(in: 4..<(4 + length))) as? [String: Any])
        return (metadata, data.subdata(in: (4 + length)..<data.count))
    }
}

private final class AVCCState: @unchecked Sendable {
    private let lock = NSLock()
    private var submissions: [Int] = []
    private var callbacks: [@Sendable (Result<H264Encoder.Encoded?, any Error>) -> Void] = []
    private var received: [Data] = []
    private var failures = 0
    var widths: [Int] { lock.withLock { submissions } }
    var packets: [Data] { lock.withLock { received } }
    var errors: Int { lock.withLock { failures } }
    func submit(
        _ buffer: CVPixelBuffer, completion: @escaping @Sendable (Result<H264Encoder.Encoded?, any Error>) -> Void
    ) {
        lock.withLock {
            submissions.append(CVPixelBufferGetWidth(buffer))
            callbacks.append(completion)
        }
    }
    func complete(_ result: Result<H264Encoder.Encoded?, any Error>) {
        let callback = lock.withLock { callbacks.removeFirst() }
        callback(result)
    }
    func add(_ data: Data) { lock.withLock { received.append(data) } }
    func fail() { lock.withLock { failures += 1 } }
}
