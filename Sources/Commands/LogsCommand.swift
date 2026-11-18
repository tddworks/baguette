import BaguetteDevice
import ArgumentParser
import Foundation

/// `baguette logs --udid <UDID> [--level …] [--style …] [--predicate …] [--bundle-id …]`
///
/// Streams the booted simulator's unified log to stdout, line by
/// line, until SIGINT (Ctrl-C). Spawns `/usr/bin/log stream` inside
/// the simulator via `SimDevice.spawn…` — no `serve`, no
/// WebSocket, just a long-running pipe.
///
/// Composition: `baguette logs --udid X | grep Foo`,
/// `… > /tmp/sim.log`, `… | head -c 4096`, etc., all behave as
/// expected; stdout is line-buffered through `print`.
struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Stream the booted simulator's unified log to stdout"
    )

    /// The values `--level` / `--style` accept, read off the domain so
    /// help and error text can't drift from what `LogFilter` parses.
    static let levels = LogFilter.Level.allCases.map(\.rawValue).joined(separator: " | ")
    static let styles = LogFilter.Style.allCases.map(\.rawValue).joined(separator: " | ")

    @OptionGroup var options: DeviceOption

    @Option(help: "Minimum log level: \(Self.levels)")
    var level: String = "info"

    @Option(help: "Output style: \(Self.styles)")
    var style: String = "default"

    @Option(help: "NSPredicate string passed to `log stream --predicate` verbatim")
    var predicate: String?

    @Option(name: .customLong("bundle-id"),
            help: "Convenience: filter to a specific process by bundle / image name. ANDs with --predicate when both given.")
    var bundleId: String?

    /// The filter the flags ask for, or a refusal naming the values allowed.
    func filter() throws -> LogFilter {
        guard let lvl = LogFilter.Level(wire: level) else {
            throw ArgumentRefusal("logs: invalid --level '\(level)' (use \(Self.levels))")
        }
        guard let sty = LogFilter.Style(wire: style) else {
            throw ArgumentRefusal("logs: invalid --style '\(style)' (use \(Self.styles))")
        }
        return LogFilter(level: lvl, style: sty, predicate: predicate, bundleId: bundleId)
    }

    func run() async throws {
        let filter: LogFilter
        do { filter = try self.filter() } catch let refusal as ArgumentRefusal {
            log(refusal.message)
            throw ExitCode.failure
        }

        let device = try options.device()
        let logs = try orExit { try device.require(.logs) }

        // Use FileHandle directly — `print` adds a trailing newline that
        // doubles up after our line split.
        let session = LogsSession(
            stream: logs,
            write: { line in
                if let data = (line + "\n").data(using: .utf8) {
                    try? FileHandle.standardOutput.write(contentsOf: data)
                }
            },
            warn: { log($0) }
        )

        // SIGINT handler: clean stop + exit 0. We install a
        // DispatchSourceSignal so the default handler doesn't kill
        // us mid-pipe.
        signal(SIGINT, SIG_IGN)
        let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigSource.setEventHandler { session.stop() }
        sigSource.resume()

        do {
            try await session.follow(filter)
        } catch {
            log("logs: \(error)")
            throw ExitCode.failure
        }
    }
}

/// One `baguette logs` run: a device's log stream, followed until it ends
/// on its own or the user stops it — whichever comes first ends the
/// follow, exactly once.
final class LogsSession: @unchecked Sendable {
    private let stream: any LogStream
    private let write: @Sendable (String) -> Void
    private let warn: @Sendable (String) -> Void

    private let lock = NSLock()
    private var ended = false
    private var waiting: CheckedContinuation<Void, Never>?

    init(
        stream: any LogStream,
        write: @escaping @Sendable (String) -> Void,
        warn: @escaping @Sendable (String) -> Void
    ) {
        self.stream = stream
        self.write = write
        self.warn = warn
    }

    /// Start the stream and write each line until the session ends.
    /// Throws when the stream can't start.
    func follow(_ filter: LogFilter) async throws {
        try stream.start(
            filter: filter,
            onLine: { [write] line in write(line) },
            onTerminate: { [weak self, warn] error in
                if let error { warn("logs: stream ended: \(error)") }
                self?.end()
            }
        )
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if ended {
                lock.unlock()
                continuation.resume()
            } else {
                waiting = continuation
                lock.unlock()
            }
        }
    }

    /// Stop the stream and end the session.
    func stop() {
        stream.stop()
        end()
    }

    private func end() {
        lock.lock()
        if ended { lock.unlock(); return }
        ended = true
        let continuation = waiting
        waiting = nil
        lock.unlock()
        continuation?.resume()
    }
}
