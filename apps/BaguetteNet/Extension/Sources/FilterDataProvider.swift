import Foundation
import NetworkExtension
import BaguetteNetKit
import os.log

/// The content-filter provider. Apple instantiates this for every new
/// socket flow; we scope to the simulator's flows (via `ProfileStore`'s
/// match keys) and apply the current `NetworkProfile`.
///
/// All the *decisions* come from the pure Shared types
/// (`ProfileStore.matches`, `ThrottleEngine.verdict`); this file is the
/// thin adapter that turns those into `NEFilter*` verdicts and schedules
/// the pause/resume. The `NEFilter*` calls are the irreducible,
/// integration-only part.
final class FilterDataProvider: NEFilterDataProvider {
    private let log = Logger(subsystem: "com.tddworks.baguette.net", category: "filter")
    private let store = ProfileStore()
    /// Per-flow running byte totals, keyed by flow identifier.
    private var bytesByFlow: [String: Int] = [:]

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        log.info("filter started")
        completionHandler(nil)
    }

    override func stopFilter(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        log.info("filter stopped: \(reason.rawValue, privacy: .public)")
        bytesByFlow.removeAll()
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        let profile = store?.profile ?? .unthrottled
        // Only touch flows we were told to match; everything else (the
        // rest of the Mac) passes untouched. On macOS the source app comes
        // from the audit token, resolved to its signing identifier.
        let sourceId = SourceApp.signingIdentifier(auditToken: flow.sourceAppAuditToken)
        guard store?.matches(sourceAppIdentifier: sourceId) == true,
              !profile.isUnthrottled else {
            return .allow()
        }
        if profile.isOffline { return .drop() }
        // Ask to see the bytes so we can meter and throttle them.
        return .filterDataVerdict(
            withFilterInbound: true, peekInboundBytes: Int.max,
            filterOutbound: true, peekOutboundBytes: Int.max
        )
    }

    override func handleInboundData(from flow: NEFilterFlow,
                                    readBytesStartOffset offset: Int,
                                    readBytes: Data) -> NEFilterDataVerdict {
        throttle(flow: flow, byteCount: readBytes.count)
    }

    override func handleOutboundData(from flow: NEFilterFlow,
                                     readBytesStartOffset offset: Int,
                                     readBytes: Data) -> NEFilterDataVerdict {
        throttle(flow: flow, byteCount: readBytes.count)
    }

    // MARK: - Throttle (decision is pure; scheduling is the adapter)

    private func throttle(flow: NEFilterFlow, byteCount: Int) -> NEFilterDataVerdict {
        let profile = store?.profile ?? .unthrottled
        let key = flow.identifier.uuidString
        let total = (bytesByFlow[key] ?? 0) + byteCount
        bytesByFlow[key] = total

        let verdict = ThrottleEngine(profile: profile).verdict(forBytes: byteCount, totalBytesSoFar: total)
        switch verdict {
        case .allow:
            return .allow()
        case .drop:
            bytesByFlow[key] = nil
            return .drop()
        case .pause(let seconds):
            // Hold the flow, then release it after the simulated link
            // would have delivered this much data.
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.resumeFlow(flow, with: NEFilterDataVerdict.allow())
            }
            return .pause()
        }
    }
}
