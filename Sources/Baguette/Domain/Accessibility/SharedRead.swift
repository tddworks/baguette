import Foundation

/// One read many callers share: whoever asks while a read is in flight
/// waits for that read and gets its answer (or its failure) instead of
/// starting another. A phone's accessibility service serves one session at
/// a time and closes a second, and an inspector asks again on every hover
/// and click, so reads of one phone go through one of these.
final class SharedRead<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight: Flight?

    private final class Flight {
        let done = DispatchGroup()
        var result: Result<Value, any Error>?
        init() { done.enter() }
    }

    func read(_ body: () throws -> Value) throws -> Value {
        let (flight, leads) = lock.withLock { () -> (Flight, Bool) in
            if let inFlight { return (inFlight, false) }
            let flight = Flight()
            inFlight = flight
            return (flight, true)
        }
        if leads {
            let result = Result { try body() }
            lock.withLock {
                flight.result = result
                inFlight = nil
            }
            flight.done.leave()
        } else {
            flight.done.wait()
        }
        return try lock.withLock { flight.result! }.get()
    }
}
