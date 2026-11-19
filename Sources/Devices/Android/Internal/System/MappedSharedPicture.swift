import Foundation

/// A `SharedPicture` as a file in the temporary folder, `capacity` bytes,
/// mapped shared — the emulator maps the same file and draws into it.
/// Integration-only.
final class MappedSharedPicture: SharedPicture, @unchecked Sendable {
    struct Failure: Error {}

    let handle: String
    let capacity: Int
    let pixels: UnsafeRawPointer
    private let path: String
    private let lock = NSLock()
    private var closed = false

    init(capacity: Int) throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("baguette-emulator-\(UUID().uuidString).rgba").path
        let fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw Failure() }
        defer { Darwin.close(fd) }
        guard ftruncate(fd, off_t(capacity)) == 0,
              let mapped = mmap(nil, capacity, PROT_READ, MAP_SHARED, fd, 0), mapped != MAP_FAILED
        else { unlink(path); throw Failure() }
        self.capacity = capacity
        self.pixels = UnsafeRawPointer(mapped)
        handle = "file://" + path
    }

    func close() {
        guard lock.withLock({ defer { closed = true }; return !closed }) else { return }
        munmap(UnsafeMutableRawPointer(mutating: pixels), capacity)
        unlink(path)
    }

    deinit { close() }
}
