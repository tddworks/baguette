import Foundation

/// How a read of the frontmost app chooses between its two routes.
///
/// The host bridge names the frontmost app in milliseconds, but it is
/// not enough on its own: on iOS 26.5 it can answer empty, and a freshly
/// launched app shows it an empty tree until a guest accessibility client
/// has connected. The guest helper settles both, at about half a second a
/// run, so it runs only when the bridge could not read the app. Each read
/// asks afresh; no PID outlives its query.
enum AXFrontmostRead {
    enum Source: Equatable, Sendable {
        case bridge
        case guest
    }

    static func read(
        bridge: () -> Int32?,
        guest: () throws -> Int32,
        tree: (Int32, Source) throws -> AXNode?
    ) throws -> AXNode? {
        if let pid = bridge(), pid > 0,
            let answer = try? tree(pid, .bridge), !answer.children.isEmpty
        {
            return answer
        }
        return try tree(try guest(), .guest)
    }
}
