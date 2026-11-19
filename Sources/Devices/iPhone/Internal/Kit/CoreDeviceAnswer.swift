import Foundation

/// Waiting on CoreDevice from a caller that can't wait asynchronously.
/// CoreDevice's calls are `async`; the adapters that make them are not, so
/// each call runs on a detached task while the caller blocks for at most a
/// while — a phone asleep or a stalled tunnel never answers.
enum CoreDeviceAnswer {
    /// `call`'s answer, or what it failed with; `CoreDeviceError.noAnswer`
    /// once `seconds` pass without one. A late answer is dropped: the task
    /// keeps what `call` holds alive until then.
    static func wait<Value>(
        upTo seconds: Double, for what: String,
        _ call: sending @escaping () async throws -> Value
    ) throws -> Value {
        let answer = Answer<Value>()
        Task.detached {
            do { answer.result = .success(try await call()) } catch { answer.result = .failure(error) }
            answer.done.signal()
        }
        guard answer.done.wait(timeout: .now() + seconds) == .success, let result = answer.result else {
            throw CoreDeviceError.noAnswer(what)
        }
        return try result.get()
    }

    private final class Answer<Value>: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var result: Result<Value, any Error>?
    }
}
