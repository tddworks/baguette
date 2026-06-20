import Foundation
import Darwin

/// `CameraFrameSink` backed by a fixed-size mmap'd file. Every write
/// rewrites the 24-byte header plus the pixel payload at offset 24,
/// then `msync(MS_SYNC)`s so the in-sim dylib's reader picks up the
/// new sequence on its next display-link tick.
///
/// Path note: the in-sim reader hardcodes `/tmp/SimCam.bgra` (the
/// upstream SimCam project's path). baguette's production callers
/// pass that same path; tests pass a unique path under
/// `NSTemporaryDirectory()`.
///
/// Coexistence: only one producer should drive `/tmp/SimCam.bgra` at
/// a time. The dylib doesn't care which producer; if both SimCamMac
/// and baguette write the same file the dylib will see whichever
/// frame landed last. The Camera WS route refuses to start a second
/// session.
final class SharedMemoryFrameSink: CameraFrameSink, @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var buffer: UnsafeMutableRawPointer?

    init(path: String) throws {
        self.path = path
        try openAndMap()
    }

    deinit { unmap() }

    func write(_ frame: CameraFrame, flags: CameraFlags) throws {
        lock.lock(); defer { lock.unlock() }
        guard let base = buffer else {
            throw SharedMemoryFrameSinkError.notOpen
        }

        let header = SharedFrameLayout.encodeHeader(
            sequence: frame.sequence,
            timestampMs: frame.timestampMs,
            width: frame.width,
            height: frame.height,
            flags: flags.packed()
        )
        header.withUnsafeBufferPointer { headerPtr in
            if let src = headerPtr.baseAddress {
                memcpy(base, src, SharedFrameLayout.headerSize)
            }
        }
        frame.pixels.withUnsafeBytes { pixelBytes in
            if let src = pixelBytes.baseAddress {
                memcpy(
                    base.advanced(by: SharedFrameLayout.headerSize),
                    src,
                    frame.expectedPixelByteCount
                )
            }
        }
        msync(base, SharedFrameLayout.headerSize + frame.expectedPixelByteCount, MS_SYNC)
    }

    // MARK: - Private

    private func openAndMap() throws {
        let cPath = path.withCString { strdup($0)! }
        defer { free(cPath) }
        let fd = open(cPath, O_CREAT | O_RDWR, 0o600)
        if fd == -1 {
            throw SharedMemoryFrameSinkError.openFailed(path: path, errno: errno)
        }
        if ftruncate(fd, off_t(SharedFrameLayout.totalByteCount)) == -1 {
            let err = errno
            Darwin.close(fd)
            throw SharedMemoryFrameSinkError.truncateFailed(errno: err)
        }
        guard let base = mmap(
            nil,
            SharedFrameLayout.totalByteCount,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            fd,
            0
        ), base != UnsafeMutableRawPointer(bitPattern: -1) else {
            let err = errno
            Darwin.close(fd)
            throw SharedMemoryFrameSinkError.mmapFailed(errno: err)
        }
        self.fd = fd
        self.buffer = base
    }

    private func unmap() {
        lock.lock(); defer { lock.unlock() }
        if let base = buffer {
            munmap(base, SharedFrameLayout.totalByteCount)
            buffer = nil
        }
        if fd != -1 {
            Darwin.close(fd)
            fd = -1
        }
    }
}

enum SharedMemoryFrameSinkError: Error, Equatable, CustomStringConvertible {
    case openFailed(path: String, errno: Int32)
    case truncateFailed(errno: Int32)
    case mmapFailed(errno: Int32)
    case notOpen

    var description: String {
        switch self {
        case .openFailed(let path, let err):
            return "open(\(path)) failed: \(String(cString: strerror(err)))"
        case .truncateFailed(let err):
            return "ftruncate failed: \(String(cString: strerror(err)))"
        case .mmapFailed(let err):
            return "mmap failed: \(String(cString: strerror(err)))"
        case .notOpen:
            return "shared-memory frame sink is not open"
        }
    }
}
