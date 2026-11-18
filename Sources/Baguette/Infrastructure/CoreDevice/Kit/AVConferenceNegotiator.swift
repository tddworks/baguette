import Foundation
import ObjectiveC

/// AVConference's media-stream negotiator, which writes the offer a phone's
/// screen stream starts from: the codecs, resolutions and bitrates this Mac
/// takes. Objective-C, reached like SimulatorKit. Making the offer needs no
/// entitlement; only receiving through `avconferenced` would, and baguette
/// receives the RTP itself (`MediaStreamScreen`).
enum AVConferenceNegotiator {
    /// Mode 5 is video; TCP-typed transport and network type 1, as Xcode asks.
    static func videoOffer() throws -> Data {
        _ = dlopen("/System/Library/PrivateFrameworks/AVConference.framework/AVConference", RTLD_NOW)
        guard let type = NSClassFromString("AVCMediaStreamNegotiator") as? NSObject.Type else {
            throw NegotiatorError.unavailable
        }
        typealias InitWithMode = @convention(c) (AnyObject, Selector, Int, NSDictionary, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        let selector = NSSelectorFromString("initWithMode:options:error:")
        guard let implementation = class_getMethodImplementation(type, selector) else { throw NegotiatorError.unavailable }
        let options: NSDictionary = [
            "AVCMediaStreamNegotiatorAccessNetworkType": 1,
            "AVCMediaStreamNegotiatorTransportProtocolType": 2,
        ]
        var error: NSError?
        let negotiator = unsafeBitCast(implementation, to: InitWithMode.self)(
            type.perform(NSSelectorFromString("alloc")).takeUnretainedValue(), selector, 5, options, &error)
        guard let offer = (negotiator as? NSObject)?.value(forKey: "offer") as? Data else {
            throw error ?? NegotiatorError.unavailable
        }
        return offer
    }

    enum NegotiatorError: Error { case unavailable }
}
