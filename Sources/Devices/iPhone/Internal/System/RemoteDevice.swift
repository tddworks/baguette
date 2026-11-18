import Foundation

#if COREDEVICE

/// A device as CoreDevice lists it.
struct RemoteDevice: @unchecked Sendable {
    let object: RemoteDeviceObject

    var identifier: UUID { object.identifier() }

    /// Open `kind` on this device. Blocks until CoreDevice answers.
    func open(_ kind: CapabilityKind) throws -> OpenedCapability {
        guard let type = CoreDeviceFramework.symbol(kind.typeSymbol),
              let conformance = CoreDeviceFramework.symbol(kind.conformanceSymbol)
        else { throw CoreDeviceError.unavailable }
        let capability = OpenedCapability()
        let (object, symbols) = (self.object, Symbols(type: type, conformance: conformance))
        return try CoreDeviceAnswer.wait(upTo: 15, for: "opening \(kind.typeSymbol)") {
            // CapabilityStaticMember<T> holds nothing, but is resilient: the
            // call takes its address, T's metadata and T's conformance.
            let member = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
            defer { member.deallocate() }
            try await object.implementation(capability.existential, member, symbols.type, symbols.conformance)
            capability.isOpen = true
            return capability
        }
    }

    /// Start the device's live screen stream (`MediaStreamFunctions
    /// .startMediaStream(with:)`), its request made by `makeRequest` once
    /// the tunnel is up; the answer is the `StartResponse`'s JSON (see
    /// `MediaStreamHandshake`). Blocks until CoreDevice answers.
    func startMediaStream(_ makeRequest: @escaping @Sendable () throws -> [String: Any]) throws -> [String: Any] {
        guard let requestType = CoreDeviceFramework.type("$s10CoreDevice0B11MediaStreamV12StartRequestVMa") as? Decodable.Type,
              let responseType = CoreDeviceFramework.type("$s10CoreDevice0B11MediaStreamV13StartResponseVMa"),
              let supportType = CoreDeviceFramework.type("$s10CoreDevice0B11MediaStreamV19SupportInfoResponseVMa"),
              let functions = CoreDeviceFramework.symbol("$s10CoreDevice20MediaStreamFunctionsVN"),
              CoreDeviceFramework.valueSize(functions) <= MemoryLayout<MediaStreamFunctionsWords>.size
        else { throw CoreDeviceError.unavailable }
        let handshake = MediaStreamHandshake(requestType: requestType, responseType: responseType, supportType: supportType)
        let call = MediaStreamCall(object: object, handshake: handshake, makeRequest: makeRequest)
        guard let json = try CoreDeviceAnswer.wait(upTo: 20, for: "starting the stream", { try await call.run() })
        else { throw CoreDeviceError.unavailable }
        return json
    }

    private struct Symbols: @unchecked Sendable {
        let type: UnsafeRawPointer
        let conformance: UnsafeRawPointer
    }
}

#else

/// A device as CoreDevice lists it — never, in a build without CoreDevice.
struct RemoteDevice: Sendable {
    var identifier: UUID { UUID() }
    func open(_ kind: CapabilityKind) throws -> OpenedCapability { throw CoreDeviceError.unavailable }
    func startMediaStream(_ makeRequest: @escaping @Sendable () throws -> [String: Any]) throws -> [String: Any] {
        throw CoreDeviceError.unavailable
    }
}

#endif
