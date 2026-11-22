import Foundation
import Mockable
import Testing
@testable import Baguette
@testable import BaguetteDevice

/// The Mac's pointer shape, watched for whoever is viewing: a
/// `baguette pointer-shapes` process — a run loop of its own, which a server
/// lacks — says each change; every viewer hears it.
@Suite("ChildPointerShapes")
struct ChildPointerShapesTests {
    static let arrow = PointerShape(id: "57a1d610", hotspot: Point(x: 5, y: 5), size: Size(width: 28, height: 40), png: Data([1, 2, 3]))
    static let ibeam = PointerShape(id: "3de4a52b", hotspot: Point(x: 12, y: 11), size: Size(width: 23, height: 22), png: Data([4, 5]))

    /// The `pointer-shapes` process, played by the test: it says what the test hands it.
    final class ShapesProcess: @unchecked Sendable {
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
        var shapes: ChildPointerShapes { ChildPointerShapes(executable: URL(fileURLWithPath: "/usr/local/bin/baguette"), makeProcess: { self.process }) }
    }

    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var _ids: [String] = []
        var ids: [String] { lock.withLock { _ids } }
        func hear(_ shape: PointerShape) { lock.withLock { _ids.append(shape.id) } }
    }

    /// `pointer-shapes` processes, a new one each start, kept alive as a real
    /// one is until it exits; each exit played by the test. `refusing`: the
    /// starts that fail, by their number.
    final class ShapesProcesses: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [MockSubprocess] = []
        private var exits: [@Sendable (Int32) -> Void] = []
        private let refusing: Set<Int>
        init(refusing: Set<Int> = []) { self.refusing = refusing }
        /// How many were started, the refused ones too.
        var started: Int { lock.withLock { made.count } }
        func make() -> any Subprocess {
            let process = MockSubprocess()
            let refused = lock.withLock { () -> Bool in made.append(process); return refusing.contains(made.count - 1) }
            given(process).run(executable: .any, arguments: .any, onBytes: .any, onExit: .any)
                .willProduce { [self] _, _, _, onExit in
                    if refused { throw CocoaError(.executableNotLoadable) }
                    lock.withLock { exits.append(onExit) }
                }
            given(process).terminate().willReturn()
            return process
        }
        func exit(_ n: Int) { lock.withLock { exits[n] }(0) }
        var shapes: ChildPointerShapes {
            ChildPointerShapes(executable: URL(fileURLWithPath: "/usr/local/bin/baguette"), makeProcess: { self.make() })
        }
    }

    @Test func `should start the process again for the next viewer when it couldn't start`() {
        let processes = ShapesProcesses(refusing: [0])
        let shapes = processes.shapes
        _ = shapes.watch { _ in }
        _ = shapes.watch { _ in }
        #expect(processes.started == 2)
    }

    @Test func `should start the process again for the next viewer when it ended on its own`() {
        let processes = ShapesProcesses()
        let shapes = processes.shapes
        _ = shapes.watch { _ in }
        processes.exit(0)
        _ = shapes.watch { _ in }
        #expect(processes.started == 2)
    }

    @Test func `should start one process when many viewers start watching at once`() {
        let processes = ShapesProcesses()
        let shapes = processes.shapes
        DispatchQueue.concurrentPerform(iterations: 64) { _ in _ = shapes.watch { _ in } }
        #expect(processes.started == 1)
    }

    @Test func `should keep the running process when a process that ended earlier says so late`() {
        let processes = ShapesProcesses()
        let shapes = processes.shapes
        shapes.watch { _ in }.end()          // process 0 started, then ended
        let watching = shapes.watch { _ in } // process 1
        processes.exit(0)                      // process 0's exit arrives now
        _ = shapes.watch { _ in }            // joins process 1
        #expect(processes.started == 2)
        watching.end()
    }

    @Test func `should start watching the Mac's pointer once, for its first viewer`() {
        let process = ShapesProcess()
        let shapes = process.shapes
        _ = shapes.watch { _ in }
        _ = shapes.watch { _ in }
        #expect(process.runs == [["pointer-shapes"]])
    }

    @Test func `should tell every viewer each new shape, however the lines arrive`() {
        let process = ShapesProcess()
        let shapes = process.shapes
        let (first, second) = (Heard(), Heard())
        _ = shapes.watch(first.hear)
        _ = shapes.watch(second.hear)
        let line = Self.ibeam.line
        process.says(Self.arrow.line + "\n" + String(line.prefix(10)))
        process.says(String(line.dropFirst(10)) + "\n")
        #expect(first.ids == ["57a1d610", "3de4a52b"])
        #expect(second.ids == ["57a1d610", "3de4a52b"])
    }

    @Test func `should tell a viewer who joins the shape the pointer has now, at once`() {
        let process = ShapesProcess()
        let shapes = process.shapes
        _ = shapes.watch { _ in }
        process.says(Self.ibeam.line + "\n")
        let late = Heard()
        _ = shapes.watch(late.hear)
        #expect(late.ids == ["3de4a52b"])
    }

    @Test func `should keep each shape's image for a page to fetch by id`() {
        let process = ShapesProcess()
        let shapes = process.shapes
        _ = shapes.watch { _ in }
        process.says(Self.arrow.line + "\n" + Self.ibeam.line + "\n")
        #expect(shapes.image(id: "57a1d610") == Data([1, 2, 3]))
        #expect(shapes.image(id: "3de4a52b") == Data([4, 5]))
        #expect(shapes.image(id: "nope") == nil)
    }

    @Test func `should stop watching when the last viewer leaves, and tell a viewer who left nothing`() {
        let process = ShapesProcess()
        let shapes = process.shapes
        let gone = Heard()
        let first = shapes.watch(gone.hear)
        let second = shapes.watch { _ in }
        first.end()
        process.says(Self.ibeam.line + "\n")
        #expect(gone.ids.isEmpty)
        #expect(process.terminated == 0)
        second.end()
        #expect(process.terminated == 1)
    }
}
