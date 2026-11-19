import Foundation

/// A value of a type known only at run time — one of CoreDevice's,
/// reached by its metadata — at an address CoreDevice reads or writes.
enum RuntimeValue {
    /// The value of `type` at `pointer`, moved out and encoded as JSON;
    /// nil when it isn't `Encodable` (it is destroyed either way).
    static func json(movingFrom pointer: UnsafeMutableRawPointer, as type: Any.Type) -> [String: Any]? {
        func open<T>(_: T.Type) -> [String: Any]? {
            let value = pointer.assumingMemoryBound(to: T.self).move()
            guard let encodable = value as? Encodable,
                  let data = try? JSONEncoder().encode(EncodableBox(encodable))
            else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        return _openExistential(type, do: open)
    }

    /// The value of `type` at `pointer`, destroyed.
    static func destroy(at pointer: UnsafeMutableRawPointer, as type: Any.Type) {
        func open<T>(_: T.Type) { _ = pointer.assumingMemoryBound(to: T.self).move() }
        _openExistential(type, do: open)
    }

    private struct EncodableBox: Encodable {
        let value: Encodable
        init(_ value: Encodable) { self.value = value }
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    }
}

/// A value held at an address for a call that borrows it, until `release`.
struct BorrowedValue {
    let pointer: UnsafeMutableRawPointer
    let release: () -> Void

    init(_ value: Any) {
        func hold<T>(_ value: T) -> (UnsafeMutableRawPointer, () -> Void) {
            let typed = UnsafeMutablePointer<T>.allocate(capacity: 1)
            typed.initialize(to: value)
            return (UnsafeMutableRawPointer(typed), { typed.deinitialize(count: 1); typed.deallocate() })
        }
        (pointer, release) = _openExistential(value, do: hold)
    }
}
