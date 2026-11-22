import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// The Mac's pointer shape, watched for whoever is viewing: a
/// `baguette pointer-shapes` process — a run loop of its own, which a server
/// lacks — says each change; every viewer hears it.
@Suite("PointerShapes")
struct PointerShapesTests {
    static let arrow = PointerShape(id: "57a1d610", hotspot: Point(x: 5, y: 5), size: Size(width: 28, height: 40), png: Data([1, 2, 3]))
    static let ibeam = PointerShape(id: "3de4a52b", hotspot: Point(x: 12, y: 11), size: Size(width: 23, height: 22), png: Data([4, 5]))

    /// The helper process, played by the test: it says what the test hands it.
    final class Helper: @unchecked Sendable {
        let process = MockSubprocess()
        private let lock = NSLock()
        private var _runs: [[String]] = []
        private var _terminated = 0
        private var onBytes: (@Sendable (Data) -> Void)?
        var runs: [[String]] { lock.withLock { _runs } }
        var terminated: Int { lock.withLock { _terminated } }

        init() {
            given(process).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any)
                .willProduce { [self] _, arguments, onBytes, _ in lock.withLock { _runs.append(arguments); self.onBytes = onBytes } }
            given(process).terminate().willProduce { [self] in lock.withLock { _terminated += 1 } }
        }

        func says(_ text: String) { lock.withLock { onBytes }?(Data(text.utf8)) }
        var shapes: PointerShapes { PointerShapes(executable: URL(fileURLWithPath: "/usr/local/bin/baguette"), makeProcess: { self.process }) }
    }

    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var _ids: [String] = []
        var ids: [String] { lock.withLock { _ids } }
        func hear(_ shape: PointerShape) { lock.withLock { _ids.append(shape.id) } }
    }

    @Test func `should start watching the Mac's pointer once, for its first viewer`() {
        let helper = Helper()
        let shapes = helper.shapes
        _ = shapes.watch { _ in }
        _ = shapes.watch { _ in }
        #expect(helper.runs == [["pointer-shapes"]])
    }

    @Test func `should tell every viewer each new shape, however the lines arrive`() {
        let helper = Helper()
        let shapes = helper.shapes
        let (first, second) = (Heard(), Heard())
        _ = shapes.watch(first.hear)
        _ = shapes.watch(second.hear)
        let line = Self.ibeam.line
        helper.says(Self.arrow.line + "\n" + String(line.prefix(10)))
        helper.says(String(line.dropFirst(10)) + "\n")
        #expect(first.ids == ["57a1d610", "3de4a52b"])
        #expect(second.ids == ["57a1d610", "3de4a52b"])
    }

    @Test func `should tell a viewer who joins the shape the pointer has now, at once`() {
        let helper = Helper()
        let shapes = helper.shapes
        _ = shapes.watch { _ in }
        helper.says(Self.ibeam.line + "\n")
        let late = Heard()
        _ = shapes.watch(late.hear)
        #expect(late.ids == ["3de4a52b"])
    }

    @Test func `should keep each shape's image for a page to fetch by id`() {
        let helper = Helper()
        let shapes = helper.shapes
        _ = shapes.watch { _ in }
        helper.says(Self.arrow.line + "\n" + Self.ibeam.line + "\n")
        #expect(shapes.image(id: "57a1d610") == Data([1, 2, 3]))
        #expect(shapes.image(id: "3de4a52b") == Data([4, 5]))
        #expect(shapes.image(id: "nope") == nil)
    }

    @Test func `should stop watching when the last viewer leaves, and tell a viewer who left nothing`() {
        let helper = Helper()
        let shapes = helper.shapes
        let gone = Heard()
        let first = shapes.watch(gone.hear)
        let second = shapes.watch { _ in }
        first.end()
        helper.says(Self.ibeam.line + "\n")
        #expect(gone.ids.isEmpty)
        #expect(helper.terminated == 0)
        second.end()
        #expect(helper.terminated == 1)
    }
}
