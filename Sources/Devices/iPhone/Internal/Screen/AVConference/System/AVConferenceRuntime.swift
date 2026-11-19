import Foundation

/// AVConference, loaded at runtime and reached through typed
/// `objc_msgSend` calls — no headers, no link, no entitlement; each call
/// is one the in-process spike measured (docs/features/real-devices/design.md).
/// Integration-only.
enum AVConferenceRuntime {
    static let isLoaded = dlopen("/System/Library/PrivateFrameworks/AVConference.framework/AVConference",
                                 RTLD_NOW | RTLD_LOCAL) != nil
    static var negotiatorClass: AnyClass? { isLoaded ? NSClassFromString("AVCMediaStreamNegotiator") : nil }
    static var streamClass: AnyClass? { isLoaded ? NSClassFromString("AVCVideoStream") : nil }

    /// The negotiator's options: CoreDevice's screen sharing, as its offer says.
    nonisolated(unsafe) static let negotiatorOptions: NSDictionary = [
        "AVCMediaStreamNegotiatorTransportProtocolType": 2,
        "AVCMediaStreamNegotiatorAccessNetworkType": 1,
    ]

    nonisolated(unsafe) private static let send = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")!

    static func alloc(_ cls: AnyClass) -> AnyObject? { object(cls, "alloc") }

    static func object(_ receiver: AnyObject, _ selector: String) -> AnyObject? {
        unsafeBitCast(send, to: (@convention(c) (AnyObject, Selector) -> AnyObject?).self)(
            receiver, NSSelectorFromString(selector))
    }

    static func bool(_ receiver: AnyObject, _ selector: String) -> Bool {
        unsafeBitCast(send, to: (@convention(c) (AnyObject, Selector) -> Bool).self)(
            receiver, NSSelectorFromString(selector))
    }

    static func void(_ receiver: AnyObject, _ selector: String) {
        unsafeBitCast(send, to: (@convention(c) (AnyObject, Selector) -> Void).self)(
            receiver, NSSelectorFromString(selector))
    }

    /// `initWithMode:options:error:`
    static func negotiator(mode: Int, error: inout NSError?) -> AnyObject? {
        guard let cls = negotiatorClass, let allocated = alloc(cls) else { return nil }
        typealias Call = @convention(c) (AnyObject, Selector, Int, NSDictionary, UnsafeMutablePointer<NSError?>) -> AnyObject?
        return unsafeBitCast(send, to: Call.self)(
            allocated, NSSelectorFromString("initWithMode:options:error:"), mode, negotiatorOptions, &error)
    }

    /// `setAnswer:withError:`
    static func setAnswer(_ negotiator: AnyObject, _ answer: Data, error: inout NSError?) -> Bool {
        typealias Call = @convention(c) (AnyObject, Selector, NSData, UnsafeMutablePointer<NSError?>) -> Bool
        return unsafeBitCast(send, to: Call.self)(
            negotiator, NSSelectorFromString("setAnswer:withError:"), answer as NSData, &error)
    }

    /// `generateMediaStreamConfigurationWithError:` and its sibling for the options.
    static func generate(_ negotiator: AnyObject, _ selector: String, error: inout NSError?) -> AnyObject? {
        typealias Call = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> AnyObject?
        return unsafeBitCast(send, to: Call.self)(negotiator, NSSelectorFromString(selector), &error)
    }

    /// An `AVCVideoStream` run in this process (`avcMediaStreamOptionRunInProcess`,
    /// which never asks `avconferenced`) on the socket `descriptor`, configured.
    static func inProcessStream(on descriptor: Int32, generated: NSDictionary, configuration: AnyObject,
                                error: inout NSError?) -> AnyObject? {
        let options = NSMutableDictionary(dictionary: generated)
        options.addEntries(from: negotiatorOptions as! [AnyHashable: Any])
        options["avcMediaStreamOptionRunInProcess"] = true
        let sockets = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_fd(sockets, "avcKeySharedSocket", descriptor)
        guard let stream = stream(sockets: sockets, options: options, error: &error),
              configure(stream, configuration, error: &error)
        else { return nil }
        return stream
    }

    /// `AVCVideoStream initWithNetworkSockets:options:error:`
    private static func stream(sockets: xpc_object_t, options: NSDictionary, error: inout NSError?) -> AnyObject? {
        guard let cls = streamClass, let allocated = alloc(cls) else { return nil }
        typealias Call = @convention(c) (AnyObject, Selector, AnyObject, NSDictionary, UnsafeMutablePointer<NSError?>) -> AnyObject?
        return unsafeBitCast(send, to: Call.self)(
            allocated, NSSelectorFromString("initWithNetworkSockets:options:error:"), sockets as AnyObject, options, &error)
    }

    /// `configure:error:`
    private static func configure(_ stream: AnyObject, _ configuration: AnyObject, error: inout NSError?) -> Bool {
        typealias Call = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>) -> Bool
        return unsafeBitCast(send, to: Call.self)(stream, NSSelectorFromString("configure:error:"), configuration, &error)
    }
}

/// An AVConference call that refused, by step, with what it said.
struct AVConferenceRefusal: Error, CustomStringConvertible {
    let step: String
    let error: NSError?
    var description: String { "AVConference refused \(step)" + (error.map { ": \($0.localizedDescription)" } ?? "") }
}
