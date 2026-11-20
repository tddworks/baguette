import BaguetteDevice
import Foundation

extension ServeCommand {
    /// The server over this host's own devices, chrome, 3D models and
    /// companion phones, bound to `--host`:`--port` until it stops.
    func serve(plugins: any Plugins) async throws {
        let models = try LiveDeviceModels(rootURLs: DeviceModelRoots.standard())
        let simulators = CoreSimulators(deviceSetPath: deviceSet)
        // A camera owner whose disarm failed is released only once the
        // guest is confirmed gone from this device set.
        let cameraSessions = CameraSessions(guestTerminated: {
            try simulators.hasTerminated(udid: $0)
        })
        // Companion phones connect only while serving: their live state is
        // made here, shared by the server's ingest and the list of kinds.
        let companions = LiveCompanionPhones()
        let twinScreens = TwinScreens()
        let kinds = DeviceKinds(
            simulators: simulators,
            companions: CompanionDevices(phones: companions, screens: twinScreens)
        )
        let server = Server(
            simulators: simulators,
            chromes: LiveChromes(
                store: FileSystemChromeStore(),
                rasterizer: CoreGraphicsPDFRasterizer()
            ),
            models: models,
            deviceRenderer: RealityKitDeviceRenderer(),
            plugins: plugins,
            host: host,
            port: port,
            allowedHosts: allowedHosts,
            cameraSessions: cameraSessions,
            devices: companions,
            twinScreens: twinScreens,
            allDevices: kinds.devices,
            viewers: WebRTCViewers(connect: WebRTCViewers.onThisMac(ports: mediaPorts), stun: stun)
        )
        Self.announce(plugins)
        try await server.run()
    }
}
