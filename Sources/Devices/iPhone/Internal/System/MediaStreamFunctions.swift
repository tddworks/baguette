import Foundation

#if COREDEVICE

/// One start of a phone's media stream, carried across to the task that
/// awaits CoreDevice: `MediaStreamHandshake`'s two calls, made on
/// CoreDevice's own `MediaStreamFunctions`.
final class MediaStreamCall: @unchecked Sendable {
    private let object: RemoteDeviceObject
    private let handshake: MediaStreamHandshake
    private let makeRequest: @Sendable () throws -> [String: Any]

    init(object: RemoteDeviceObject, handshake: MediaStreamHandshake,
         makeRequest: @escaping @Sendable () throws -> [String: Any]) {
        self.object = object
        self.handshake = handshake
        self.makeRequest = makeRequest
    }

    func run() async throws -> [String: Any]? {
        var functions = MediaStreamFunctionsObject(words: mediaStreamFunctions(device: object))
        return try await handshake.run(
            supportInfo: { try await functions.supportInfo($0) },
            start: { try await functions.start($0, $1) },
            makeRequest: makeRequest)
    }
}

/// `MediaStreamFunctions(device:)` — a small resilient struct, returned
/// indirectly; sixteen words is room enough, which `startMediaStream`
/// checks against the type's own size before calling.
typealias MediaStreamFunctionsWords = (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
                                       UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)
// Weak, and left unresolved at link time (Package.swift's `-U`): a CoreDevice
// without the media stream leaves these null; `startMediaStream` checks first.
@_weakLinked @_silgen_name("$s10CoreDevice20MediaStreamFunctionsV6deviceAcA06RemoteB0C_tcfC")
private func mediaStreamFunctions(device: __owned RemoteDeviceObject) -> MediaStreamFunctionsWords

/// Stands at a `MediaStreamFunctions` value, so its methods get its address.
private struct MediaStreamFunctionsObject {
    var words: MediaStreamFunctionsWords
}
private extension MediaStreamFunctionsObject {
    /// MediaStreamFunctions.mediaStreamSupportInfo { get async throws }
    @_weakLinked @_silgen_name("$s10CoreDevice20MediaStreamFunctionsV05mediaD11SupportInfoAA0bcD0V0gH8ResponseVvg")
    mutating func supportInfo(_ result: UnsafeMutableRawPointer) async throws
    /// MediaStreamFunctions.startMediaStream(with:) async throws
    @_weakLinked @_silgen_name("$s10CoreDevice20MediaStreamFunctionsV05startcD04withAA0bcD0V13StartResponseVAG0H7RequestV_tYaKF")
    mutating func start(_ result: UnsafeMutableRawPointer, _ request: UnsafeRawPointer) async throws
}

#endif
