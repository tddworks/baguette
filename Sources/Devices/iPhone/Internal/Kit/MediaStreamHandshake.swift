import Foundation

/// The two calls that start a phone's live screen through CoreDevice's
/// `MediaStreamFunctions`, in order. The support-info query brings the
/// tunnel up (its answer is dropped); only then can the request be made,
/// since it names the tunnel's addresses. It is built as JSON and decoded
/// through CoreDevice's own `Decodable` `StartRequest`; the
/// `StartResponse` comes back as JSON. The calls themselves are
/// CoreDevice's (`MediaStreamFunctions.swift`), handed in.
package struct MediaStreamHandshake {
    let requestType: Decodable.Type
    let responseType: Any.Type
    let supportType: Any.Type

    package init(requestType: Decodable.Type, responseType: Any.Type, supportType: Any.Type) {
        self.requestType = requestType
        self.responseType = responseType
        self.supportType = supportType
    }

    /// - Parameters:
    ///   - supportInfo: writes a `supportType` into the address it is given.
    ///   - start: reads the request at its second address, writes a
    ///     `responseType` into its first.
    package func run(
        supportInfo: (UnsafeMutableRawPointer) async throws -> Void,
        start: (UnsafeMutableRawPointer, UnsafeRawPointer) async throws -> Void,
        makeRequest: () throws -> [String: Any]
    ) async throws -> [String: Any]? {
        let result = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
        defer { result.deallocate() }
        try await supportInfo(result)
        RuntimeValue.destroy(at: result, as: supportType)
        let request = try JSONDecoder().decode(
            requestType, from: JSONSerialization.data(withJSONObject: try makeRequest()))
        let held = BorrowedValue(request)
        defer { held.release() }
        try await start(result, UnsafeRawPointer(held.pointer))
        return RuntimeValue.json(movingFrom: result, as: responseType)
    }
}
