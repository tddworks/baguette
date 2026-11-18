import Foundation
import Synchronization
import Testing

@testable import Baguette
@testable import BaguetteDevice

@Suite("IndigoHIDMessageTests", .serialized)
struct IndigoHIDMessageTests {
    @Test(arguments: [false, true])
    func `should wait for the simulator to confirm a sent message and report its outcome`(fails: Bool) async throws {
        let (sends, received) = AsyncStream<Void>.makeStream()
        let client = DeferredHIDClient(onSend: {
            received.yield()
            received.finish()
        })
        let returned = Mutex(false)
        async let result: Bool = withCheckedThrowingContinuation { continuation in
            // A synchronous send must not occupy the cooperative test executor.
            Thread.detachNewThread {
                defer {
                    returned.withLock { $0 = true }
                    received.finish()
                }
                do {
                    let message = try #require(malloc(8))
                    // Timeout behavior is covered separately; completion is gated here.
                    let ok = IndigoHIDMessage.send(message, to: client, deadline: .distantFuture)
                    continuation.resume(returning: ok)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        defer { client.complete(error: nil) }
        for await _ in sends {}
        try await Task.sleep(for: .milliseconds(50))
        #expect(!returned.withLock { $0 })
        client.complete(error: fails ? Self.error : nil)
        #expect(try await result == !fails)
    }

    @Test @MainActor
    func `should confirm a sent message without needing the waiting main actor`() throws {
        let client = DeferredHIDClient(automaticResults: [nil])
        let message = try #require(malloc(8))
        #expect(IndigoHIDMessage.send(message, to: client))
        #expect(client.sentCount == 1)
    }

    @Test func `should refuse to send a message to a client that cannot send`() throws {
        let message = try #require(malloc(8))
        #expect(!IndigoHIDMessage.send(message, to: NSObject()))
    }

    @Test func `should fail a send on timeout yet still accept the late confirmation`() throws {
        let client = DeferredHIDClient()
        let message = try #require(malloc(8))
        #expect(!IndigoHIDMessage.send(message, to: client, deadline: .now()))
        #expect(client.received.wait(timeout: .now()) == .success)
        client.complete(error: nil)
        #expect(client.completed.wait(timeout: .now() + 1) == .success)
        #expect(client.sentCount == 1)
    }

    @Test func `should fail a touch when the simulator reports a transport failure`() {
        let client = DeferredHIDClient(automaticResults: [Self.error])
        let ok = IOHIDDigitizerDispatch.send(
            point: CGPoint(x: 0.25, y: 0.5), identifier: 1, phase: .up, edge: .none,
            target: IndigoHIDTouchTarget.phone, on: client
        )
        #expect(client.sentCount == 1)
        #expect(!ok)
    }

    private static var error: NSError { NSError(domain: "HID transport", code: 17) }
}

/// Implements the real Objective-C selector; the test releases completion
/// independently from method return, as SimulatorKit's send queue does.
/// Mutable state is locked; completions run only on the supplied queue.
private final class DeferredHIDClient: NSObject, @unchecked Sendable {
    let received = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var pending: Pending?
    private var count = 0
    private let automaticResults: [NSError?]?
    private let onSend: (@Sendable () -> Void)?

    init(automaticResults: [NSError?]? = nil, onSend: (@Sendable () -> Void)? = nil) {
        self.automaticResults = automaticResults
        self.onSend = onSend
    }

    var sentCount: Int { lock.withLock { count } }

    @objc(sendWithMessage:freeWhenDone:completionQueue:completion:)
    func send(
        message: UnsafeMutableRawPointer, freeWhenDone: Bool,
        completionQueue: DispatchQueue?,
        completion: (@convention(block) (NSError?) -> Void)?
    ) {
        #expect(freeWhenDone)
        #expect(completionQueue != nil)
        #expect(completion != nil)
        let index = lock.withLock {
            pending = Pending(message: message, queue: completionQueue, completion: completion)
            count += 1
            return count - 1
        }
        received.signal()
        onSend?()
        if let automaticResults { complete(error: automaticResults[index]) }
    }

    func complete(error: NSError?) {
        let delivery = lock.withLock {
            let delivery = pending
            pending = nil
            return delivery
        }
        guard let delivery else { return }
        free(delivery.message)
        // The old adapter supplies neither callback argument.
        guard let queue = delivery.queue else { return }
        queue.async {
            delivery.completion?(error)
            self.completed.signal()
        }
    }

    // Immutable envelope; the message is freed once before queue delivery.
    private final class Pending: @unchecked Sendable {
        let message: UnsafeMutableRawPointer
        let queue: DispatchQueue?
        let completion: (@convention(block) (NSError?) -> Void)?

        init(
            message: UnsafeMutableRawPointer, queue: DispatchQueue?,
            completion: (@convention(block) (NSError?) -> Void)?
        ) {
            self.message = message
            self.queue = queue
            self.completion = completion
        }
    }
}
