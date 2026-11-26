import Foundation
import Mockable

/// What starts a phone's live screen: CoreDevice's media stream, asked
/// with our request. Decides nothing — what the request says and what the
/// answer means are `MediaStreamSession`'s. The real one is
/// `CoreDeviceMediaStream`.
@Mockable
package protocol MediaStreamStarter: Sendable {
    /// Start `phone`'s stream (CoreDevice's identifier, not the UDID),
    /// asking with what `request` makes once the phone's tunnel is up;
    /// CoreDevice's answer as JSON. Blocks until CoreDevice answers.
    func start(on phone: UUID, request: @escaping @Sendable () throws -> [String: Any]) throws -> [String: Any]
}

/// Why a phone's live screen didn't start: CoreDevice doesn't list the phone,
/// or answered the start with something other than a stream.
package enum MediaStreamError: Error {
    case notListed, unexpectedAnswer
}
