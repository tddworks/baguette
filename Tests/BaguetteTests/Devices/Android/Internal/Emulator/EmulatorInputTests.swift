import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// An emulator's touchscreen through its control API —
/// with its link stood in for, and the calls read back off it.
@Suite("EmulatorInput")
struct EmulatorInputTests {
    private static let emulator = RunningEmulator(serial: "emulator-5554", avd: "baguette_pixel", port: 8554, token: "tok")
    /// The page's size in device points, and the emulator's in pixels: × 2.5.
    private static let points = Size(width: 432, height: 960)
    private static let pixels = Size(width: 1080, height: 2400)

    /// Every call written to the link, as (method, message), read back out of
    /// its HTTP/2 frames.
    private final class Recorder: @unchecked Sendable {
        let link = MockEmulatorLink()
        private let lock = NSLock()
        private var bytes = Data()

        init() {
            given(link).send(.any).willProduce { [self] data in lock.withLock { bytes += data } }
            given(link).receive().willProduce { Thread.sleep(forTimeInterval: 0.002); return nil }
            given(link).close().willReturn()
        }

        var calls: [(method: String, message: Data)] {
            var data = lock.withLock { Data(bytes.dropFirst(GRPCCall.opening.count)) }
            var calls: [(String, Data)] = []
            var method = ""
            while data.count >= 9 {
                let length = Int(data[data.startIndex]) << 16 | Int(data[data.startIndex + 1]) << 8 | Int(data[data.startIndex + 2])
                let kind = data[data.startIndex + 3]
                let payload = Data(data.dropFirst(9).prefix(length))
                if kind == 1, let path = String(data: payload, encoding: .isoLatin1),
                   let range = path.range(of: "EmulatorController/") {
                    method = String(path[range.upperBound...].prefix { $0.isLetter })
                } else if kind == 0 {
                    calls.append((method, Data(payload.dropFirst(5))))
                }
                data = Data(data.dropFirst(9 + length))
            }
            return calls
        }
    }

    private func input(_ recorder: Recorder) -> EmulatorInput {
        EmulatorInput(connection: EmulatorConnection(to: Self.emulator, openLink: { _ in recorder.link }),
                      screen: Self.pixels, pixelsPerPoint: 2.5, pause: { _ in })
    }

    private static func touches(_ fingers: (x: Int, y: Int, id: Int, pressure: Int)...) -> Data {
        EmulatorControl.TouchEvent(touches: fingers.map { .init(x: $0.x, y: $0.y, identifier: $0.id, pressure: $0.pressure) }).bytes
    }

    @Test func `should land a tap on the emulator as a finger down and up, at its pixels`() {
        let recorder = Recorder()

        #expect(input(recorder).tap(at: Point(x: 216, y: 480), size: Self.points, duration: 0, edge: nil))

        #expect(recorder.calls.map(\.method) == ["sendTouch", "sendTouch"])
        #expect(recorder.calls.map(\.message) == [Self.touches((540, 1200, 1, 1)), Self.touches((540, 1200, 1, 0))])
    }

    @Test func `should swipe as a finger down, moving, and lifted where it ends`() {
        let recorder = Recorder()

        #expect(input(recorder).swipe(from: Point(x: 0, y: 960), to: Point(x: 0, y: 0), size: Self.points, duration: 0.1))

        let messages = recorder.calls.map(\.message)
        #expect(messages.first == Self.touches((0, 2400, 1, 1)))
        #expect(messages.last == Self.touches((0, 0, 1, 0)))
        #expect(messages.count >= 4)
    }

    @Test func `should follow one finger down, moved and lifted`() {
        let recorder = Recorder()
        let input = input(recorder)

        _ = input.touch1(phase: .down, at: Point(x: 4, y: 4), size: Self.points, edge: nil)
        _ = input.touch1(phase: .move, at: Point(x: 8, y: 8), size: Self.points, edge: nil)
        _ = input.touch1(phase: .up, at: Point(x: 8, y: 8), size: Self.points, edge: nil)

        #expect(recorder.calls.map(\.message) == [Self.touches((10, 10, 1, 1)), Self.touches((20, 20, 1, 1)),
                                                  Self.touches((20, 20, 1, 0))])
    }

    @Test func `should put two fingers down as two touches`() {
        let recorder = Recorder()

        _ = input(recorder).touch2(phase: .down, first: Point(x: 4, y: 4), second: Point(x: 8, y: 8), size: Self.points)

        #expect(recorder.calls.map(\.message) == [Self.touches((10, 10, 1, 1), (20, 20, 2, 1))])
    }

    @Test func `should scroll as a finger dragging the content through the screen's middle`() {
        let recorder = Recorder()

        #expect(input(recorder).scroll(deltaX: 0, deltaY: 100))

        let messages = recorder.calls.map(\.message)
        // Down at the middle; the content moves up 100 points (250 pixels) as the finger does.
        #expect(messages.first == Self.touches((540, 1200, 1, 1)))
        #expect(messages.last == Self.touches((540, 950, 1, 0)))
    }
}
