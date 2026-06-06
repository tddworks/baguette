import SwiftUI

@main
struct BaguetteNetApp: App {
    @StateObject private var controller = NetworkExtensionController()

    var body: some Scene {
        Window("Baguette Net", id: "main") {
            ContentView()
                .environmentObject(controller)
                .frame(minWidth: 360, minHeight: 420)
        }
        .windowResizability(.contentSize)
    }
}
