import BaguetteDevice
import Foundation

/// The Mac's pointer shape, watched for whoever is viewing a Mac display. A
/// long-running server reads `NSCursor.currentSystem` once and never again; a
/// process whose run loop runs follows it (measured: every crossing between
/// text and title bar read right), so a `baguette pointer-shapes` process
/// watches and says each change. Started for the first viewer, ended when the
/// last leaves; a viewer who joins hears the shape now at once. Each shape's
/// image is kept by id, for a page to fetch once.
/// Design: docs/features/mac-screen/design.md#the-pointer.
final class PointerShapes: @unchecked Sendable {
    /// One viewer's watch; `end()` stops it hearing.
    struct Watch {
        let end: @Sendable () -> Void
    }

    private let executable: URL
    private let makeProcess: @Sendable () -> any Subprocess
    private let lock = NSLock()
    private var process: (any Subprocess)?
    private var lines = LineBuffer()
    private var current: PointerShape?
    private var images: [String: Data] = [:]
    private var viewers: [UUID: @Sendable (PointerShape) -> Void] = [:]

    init(executable: URL, makeProcess: @escaping @Sendable () -> any Subprocess) {
        self.executable = executable
        self.makeProcess = makeProcess
    }

    /// Hear every new shape — and the shape now, at once, when there is one.
    func watch(_ hear: @escaping @Sendable (PointerShape) -> Void) -> Watch {
        let id = UUID()
        let (now, start) = lock.withLock { () -> (PointerShape?, Bool) in
            viewers[id] = hear
            return (current, process == nil)
        }
        if start { begin() }
        if let now { hear(now) }
        return Watch { [weak self] in self?.leave(id) }
    }

    /// The image of the shape `id`, once it has been seen.
    func image(id: String) -> Data? {
        lock.withLock { images[id] }
    }

    private func begin() {
        let process = makeProcess()
        lock.withLock { self.process = process }
        do {
            try process.run(executable: executable, arguments: ["pointer-shapes"],
                            onBytes: { [weak self] in self?.hear($0) },
                            onExit: { [weak self] _ in self?.ended() })
        } catch {
            ended()
        }
    }

    private func hear(_ bytes: Data) {
        let (shapes, viewers) = lock.withLock { () -> ([PointerShape], [@Sendable (PointerShape) -> Void]) in
            let shapes = lines.append(bytes).compactMap(PointerShape.init(line:))
            for shape in shapes { images[shape.id] = shape.png }
            if let last = shapes.last { current = last }
            return (shapes, Array(self.viewers.values))
        }
        for shape in shapes { viewers.forEach { $0(shape) } }
    }

    private func leave(_ id: UUID) {
        let ending = lock.withLock { () -> (any Subprocess)? in
            viewers[id] = nil
            guard viewers.isEmpty else { return nil }
            defer { process = nil; lines = LineBuffer() }
            return process
        }
        ending?.terminate()
    }

    private func ended() {
        lock.withLock { process = nil; lines = LineBuffer() }
    }
}
