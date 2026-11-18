import Foundation
import ObjectiveC
import Synchronization

/// Owns an Indigo allocation and waits for its Mach send result.
/// Success confirms transport completion, not guest event consumption.
enum IndigoHIDMessage {
    private static let completionQueue = DispatchQueue(label: "baguette.hid.completion")

    /// The host deadline bounds one send. Timing out does not cancel delivery;
    /// SimulatorKit retains the message and completion until its send finishes.
    static func send(
        _ message: UnsafeMutableRawPointer, to client: AnyObject,
        deadline: DispatchTime = .now() + 5
    ) -> Bool {
        let selector = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard let cls = object_getClass(client),
            let method = class_getInstanceMethod(cls, selector)
        else {
            free(message)
            logErr("[hid] client does not support sendWithMessage:freeWhenDone:completionQueue:completion:")
            return false
        }

        // ponytail: Input is synchronous; move it to async if transport stalls
        // must not block its caller for the per-message deadline.
        let completed = DispatchSemaphore(value: 0)
        let result = Mutex<NSError?>(nil)
        let completion: @convention(block) (NSError?) -> Void = { error in
            result.withLock { $0 = error }
            completed.signal()
        }
        typealias Send =
            @convention(c) (
                AnyObject, Selector, UnsafeMutableRawPointer, Bool, DispatchQueue?,
                (@convention(block) (NSError?) -> Void)?
            ) -> Void
        let send = unsafeBitCast(method_getImplementation(method), to: Send.self)
        send(client, selector, message, true, completionQueue, completion)

        guard completed.wait(timeout: deadline) == .success else {
            logErr("[hid] completion timed out; delivery outcome unknown")
            return false
        }
        if let error = result.withLock({ $0 }) {
            logErr("[hid] send failed: \(error)")
            return false
        }
        return true
    }
}
