import ReplayKit
import SwiftUI
import TwinWire

/// The companion app is deliberately small: pair with the Mac (host
/// and port stored in the shared App Group so the broadcast extension
/// can read them) and offer the system broadcast picker. The screen
/// pipe itself lives in the extension.
@main
struct DeviceTwinApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var endpoint: String
    @State private var saved = false

    private let defaults = UserDefaults(suiteName: TwinWire.appGroup)

    init() {
        let stored = UserDefaults(suiteName: TwinWire.appGroup)?
            .string(forKey: TwinWire.endpointKey)
        _endpoint = State(initialValue: stored ?? "192.168.1.100:8421")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("baguette host") {
                    TextField("mac-address:port", text: $endpoint)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button(saved ? "Saved" : "Save") {
                        defaults?.set(endpoint, forKey: TwinWire.endpointKey)
                        if defaults?.string(forKey: TwinWire.deviceIdKey) == nil {
                            defaults?.set(
                                UIDevice.current.identifierForVendor?.uuidString
                                    ?? UUID().uuidString,
                                forKey: TwinWire.deviceIdKey
                            )
                        }
                        saved = true
                    }
                }
                Section("mirror") {
                    BroadcastPicker()
                        .frame(height: 52)
                    Text("Save the host first, then start the broadcast. The mirror appears at http://\(endpoint)/devices.json and streams from /devices/<id>/stream.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Baguette Twin")
            .onChange(of: endpoint) { saved = false }
        }
    }
}

/// The system broadcast picker, pinned to our upload extension so the
/// sheet doesn't list every broadcast app on the phone.
struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView()
        picker.preferredExtension = "com.tddworks.baguette.twin.broadcast"
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}
}
