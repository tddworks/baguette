import BaguetteDevice
import BaguetteCoreDevice
import BaguetteDeviceFamilies
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
        // This Mac shared to viewers' devices: each display made, and made main,
        // by a process of this binary; captured at the pixels it was made with.
        let baguette = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let screenShares = shareMac
            ? VirtualDisplayShares(
                displays: ChildVirtualDisplays(executable: baguette, makeProcess: { HostSubprocess() }),
                arrangement: ChildDisplayArrangement(executable: baguette, makeProcess: { HostSubprocess() }))
            : nil
        let kinds = DeviceKinds(
            simulators: simulators,
            companions: CompanionDevices(phones: companions, screens: twinScreens),
            coreDevice: .live,
            macs: shareMac ? MacDisplays.onThisMac(madePixels: { screenShares?.pixels(of: $0) }) : nil
        )
        // DeviceKit's chrome first, then the Mac frames installed here, then —
        // when shared — each Mac display's own look: no frame.
        let frames = MacFrames(folder: macFrames.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? MacFrames.standardFolder)
        let server = Server(
            simulators: simulators,
            chromes: CombinedChromes([
                LiveChromes(store: FileSystemChromeStore(), rasterizer: CoreGraphicsPDFRasterizer()),
                frames,
            ] + (shareMac ? [MacDisplayLooks(displays: { HostDisplayList.all() })] : [])),
            macFrames: frames,
            screenShares: screenShares,
            pointerShapes: shareMac ? ChildPointerShapes(executable: baguette, makeProcess: { HostSubprocess() }) : nil,
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
            viewers: WebRTCViewers(connect: WebRTCViewers.onThisMac(ports: mediaPorts), stun: stun, turn: turn)
        )
        Self.announce(plugins)
        try await server.run()
    }
}
