import Foundation
import NetworkExtension
import SystemExtensions
import BaguetteNetKit
import os.log

/// Drives the system extension's lifecycle and pushes the chosen profile.
/// This is the piece a bare CLI cannot do: only a bundled app can call
/// `OSSystemExtensionManager`. Integration-only — no unit tests; the
/// throttle decisions live in the pure Shared types.
@MainActor
final class NetworkExtensionController: NSObject, ObservableObject {
    @Published var status: String = "Idle"
    @Published var isFiltering: Bool = false

    private let extensionIdentifier = "com.tddworks.baguette.net.extension"
    private let store = ProfileStore()
    private let log = Logger(subsystem: "com.tddworks.baguette.net", category: "controller")

    /// Step 1 — activate (install + user-approve) the system extension.
    func activate() {
        status = "Requesting activation…"
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier, queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Step 2 — write the profile + match keys to the app group and enable
    /// the content filter so the provider starts applying it.
    func apply(_ profile: NetworkProfile, matchKeys: [String]) {
        store?.profile = profile
        store?.matchKeys = matchKeys
        setFilter(enabled: !profile.isUnthrottled)
    }

    /// Remove the throttle: clear the profile and disable the filter.
    func clear() {
        store?.profile = .unthrottled
        setFilter(enabled: false)
    }

    private func setFilter(enabled: Bool) {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] error in
            guard let self else { return }
            if let error { self.status = "Load failed: \(error.localizedDescription)"; return }
            if manager.providerConfiguration == nil {
                let config = NEFilterProviderConfiguration()
                config.filterSockets = true
                config.filterPackets = false
                manager.providerConfiguration = config
                manager.localizedDescription = "Baguette Net"
            }
            manager.isEnabled = enabled
            manager.saveToPreferences { error in
                Task { @MainActor in
                    if let error {
                        self.status = "Save failed: \(error.localizedDescription)"
                    } else {
                        self.isFiltering = enabled
                        self.status = enabled ? "Throttling" : "Off"
                    }
                }
            }
        }
    }
}

extension NetworkExtensionController: OSSystemExtensionRequestDelegate {
    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.status = "Approve in System Settings → Login Items & Extensions" }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in self.status = "Extension activated (\(result.rawValue))" }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in self.status = "Activation failed: \(error.localizedDescription)" }
    }
}
