import Foundation

/// Reads newline-delimited JSON commands from stdin in event-driven mode
/// and applies them to a `Stream`. Used by the `stream` subcommand so the
/// plugin can retune the running stream.
///
/// Why not `readLine()`? When stdin is a pipe (it always is for the
/// plugin's spawned subprocess), libc switches stdio to *block buffering*
/// — the small JSON commands never fill the 4 KB buffer and `readLine`
/// blocks forever. `FileHandle.standardInput.readabilityHandler` is the
/// stream-edge pattern with no buffering.
///
/// Wire format (one object per line):
///   {"cmd":"set_bitrate","bps":N}
///   {"cmd":"set_fps","fps":N}
///   {"cmd":"set_scale","scale":N}
///   {"cmd":"force_idr"}
///   {"cmd":"snapshot"}
final class ControlChannel: @unchecked Sendable {
    private weak var stream: AnyObject?
    private var buffer = Data()
    private let stdin = FileHandle.standardInput

    init(stream: any Stream) {
        self.stream = stream as AnyObject
    }

    func start() {
        stdin.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.feed(chunk)
        }
    }

    func stop() {
        stdin.readabilityHandler = nil
    }

    /// Test seam: feed bytes directly without going through stdin.
    func feed(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line: line)
        }
    }

    private func handle(line: Data) {
        guard !line.isEmpty else { return }
        let raw = String(data: line, encoding: .utf8) ?? "<non-utf8>"

        guard let object = try? JSONSerialization.jsonObject(with: line),
              let dict = object as? [String: Any],
              let cmd = dict["cmd"] as? String,
              let stream = stream as? any Stream
        else {
            log("control: invalid line \(raw)")
            return
        }

        switch cmd {
        case "set_bitrate":
            guard let bps = Self.numeric(dict["bps"]) else {
                log("control: set_bitrate missing/invalid bps in \(raw)")
                return
            }
            stream.apply(stream.config.with(bitrateBps: Int(bps)))
        case "set_fps":
            guard let fps = Self.numeric(dict["fps"]) else {
                log("control: set_fps missing/invalid fps in \(raw)")
                return
            }
            stream.apply(stream.config.with(fps: Int(fps)))
        case "set_scale":
            guard let scale = Self.numeric(dict["scale"]) else {
                log("control: set_scale missing/invalid scale in \(raw)")
                return
            }
            stream.apply(stream.config.with(scale: Int(scale)))
        case "force_idr":
            stream.requestKeyframe()
            log("control: force_idr")
        case "snapshot":
            stream.requestSnapshot()
            log("control: snapshot")
        default:
            log("control: unknown cmd \(cmd) in \(raw)")
        }
    }

    private static func numeric(_ raw: Any?) -> Double? {
        if let v = raw as? Double { return v }
        if let v = raw as? Int    { return Double(v) }
        return nil
    }
}
