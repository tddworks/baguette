import Foundation

/// The names an answer offers a verb for, `nil` when it offers none.
func offeredNames(_ answer: [String: Any]?, _ verb: String) -> [String]? {
    ((answer?["affordances"] as? [String: Any])?[verb] as? [String: Any])?["names"] as? [String]
}
