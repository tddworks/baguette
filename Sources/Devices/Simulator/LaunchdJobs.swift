import BaguetteDevice
import Foundation

/// The jobs a simulator's launchd reports through `launchctl list` —
/// one `pid<TAB>status<TAB>label` line each, `-` in the pid column for
/// a job that isn't running.
///
/// Reclaiming the input surface restarts backboardd, and SpringBoard
/// goes down with it; "the simulator is usable again" means SpringBoard
/// is back under a **new** pid, which is what this answers. Pure parse,
/// per AGENTS.md's one-shot-fetch split — the spawn is the adapter's.
struct LaunchdJobs: Equatable, Sendable {
    /// Running jobs only, keyed by label.
    var pids: [String: Int32]

    static func parsing(_ launchctlOutput: String?) -> LaunchdJobs {
        var pids: [String: Int32] = [:]
        for line in (launchctlOutput ?? "").split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3, let pid = Int32(columns[0]) else { continue }
            pids[String(columns[2])] = pid
        }
        return LaunchdJobs(pids: pids)
    }

    /// The pid of `label` if that job is running, else nil.
    func pid(of label: String) -> Int32? { pids[label] }
}
