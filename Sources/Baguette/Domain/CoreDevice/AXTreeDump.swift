import Foundation

/// The accessibility tree a phone pushes when asked: the answers its
/// accessibility service already gave to every question the host's
/// translator will ask — the frontmost app (request 4), each element's
/// attributes (5), one attribute (2), whether one can be set (3). Answering
/// the translator from here builds the same element tree a simulator gives,
/// without a round trip per question.
///
/// The phone pushes twice: an initial dump, then the additional data that
/// completes it; the second is the tree. Read through KVC from
/// `AXPTranslatorResponse` / `AXPTranslationObject`. Pure.
struct AXTreeDump: @unchecked Sendable {
    /// What the translator gets back for one question.
    enum Answer: Equatable {
        /// The phone's own response, handed back as it is.
        case response(NSObject)
        /// One attribute's value.
        case value(attribute: UInt64, NSObject)
        /// Every attribute of one element, keyed by attribute.
        case values([NSNumber: NSObject])

        static func == (lhs: Answer, rhs: Answer) -> Bool {
            switch (lhs, rhs) {
            case let (.response(a), .response(b)): return a === b
            case let (.value(x, a), .value(y, b)): return x == y && a.isEqual(b)
            case let (.values(a), .values(b)): return NSDictionary(dictionary: a).isEqual(to: b)
            default: return false
            }
        }
    }

    private struct Element: Hashable {
        let pid: Int32
        let objectID: UInt64

        init?(_ object: NSObject?) {
            guard let object,
                  let pid = (object.value(forKey: "pid") as? NSNumber)?.int32Value, pid > 0,
                  let id = (object.value(forKey: "objectID") as? NSNumber)?.uint64Value, id != 0
            else { return nil }
            self.pid = pid
            objectID = id
        }
    }

    /// The frontmost app's translation, where the tree starts.
    let root: NSObject
    /// Whether this is the push that completes the tree.
    let isComplete: Bool
    private let rootResponse: NSObject
    private let attributes: [Element: [UInt64: NSObject]]
    private let settable: [Element: [UInt64: NSObject]]
    private let global: [UInt64: NSObject]

    /// Nil unless `envelope` is a tree dump with its app.
    init?(envelope: NSObject) {
        guard let payload = envelope.value(forKey: "resultData") as? NSDictionary,
              let records = payload["treeDump"] as? [NSObject] else { return nil }
        var rootResponse: NSObject?
        var attributes: [Element: [UInt64: NSObject]] = [:]
        var settable: [Element: [UInt64: NSObject]] = [:]
        var global: [UInt64: NSObject] = [:]
        for record in records {
            let attribute = Self.number(record, "attribute")
            let element = Element(record.value(forKey: "associatedTranslationObject") as? NSObject)
            switch Self.number(record, "associatedRequestType") {
            case 4:
                rootResponse = record
            case 5:
                guard let element, let values = record.value(forKey: "resultData") as? NSDictionary else { continue }
                for case let (key as NSNumber, value as NSObject) in values {
                    attributes[element, default: [:]][key.uint64Value] = value
                }
            case 3:
                if let element { settable[element, default: [:]][attribute] = record }
            case 2:
                if let element, let value = record.value(forKey: "resultData") as? NSObject {
                    attributes[element, default: [:]][attribute] = value
                } else if element == nil {
                    global[attribute] = record
                }
            default:
                continue
            }
        }
        guard let rootResponse, let root = rootResponse.value(forKey: "translationResponse") as? NSObject else { return nil }
        self.root = root
        self.rootResponse = rootResponse
        self.attributes = attributes
        self.settable = settable
        self.global = global
        isComplete = payload["treeDumpType"] as? String == "AXPTreeDumpTypeAdditionalData"
    }

    /// The answer to a translator request of `type` about `attribute` of
    /// `element` (the request's translation), or nil when the phone didn't push it.
    func answer(type: UInt64, attribute: UInt64, element: NSObject?) -> Answer? {
        let element = Element(element)
        switch type {
        case 4:
            return .response(rootResponse)
        case 2:
            if let element, let value = attributes[element]?[attribute] { return .value(attribute: attribute, value) }
            if element == nil, let response = global[attribute] { return .response(response) }
        case 3:
            if let element, let response = settable[element]?[attribute] { return .response(response) }
        case 5:
            if let element, let values = attributes[element] {
                return .values(Dictionary(uniqueKeysWithValues: values.map { (NSNumber(value: $0.key), $0.value) }))
            }
        default:
            break
        }
        return nil
    }

    private static func number(_ object: NSObject, _ key: String) -> UInt64 {
        (object.value(forKey: key) as? NSNumber)?.uint64Value ?? 0
    }
}
