import Dispatch
import Foundation

/// The process's own terminal: stdin, and signal handlers installed with
/// `DispatchSource` so the default handler doesn't kill a run mid-pipe.
extension Terminal {
    static let standard = Terminal(
        readLine: { Swift.readLine() },
        readAll: { FileHandle.standardInput.readDataToEndOfFile() },
        onInterrupt: { signals, handler in
            let sources = signals.map { number in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler(handler: handler)
                source.resume()
                return source
            }
            let held = SignalSources(sources)
            return {
                held.cancel()
                for number in signals { signal(number, SIG_DFL) }
            }
        }
    )
}

/// The signal sources one interrupt handler holds, cancelled together.
private final class SignalSources: @unchecked Sendable {
    private let sources: [any DispatchSourceSignal]

    init(_ sources: [any DispatchSourceSignal]) { self.sources = sources }

    func cancel() { for source in sources { source.cancel() } }
}
