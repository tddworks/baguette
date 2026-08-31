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
    @State private var probe: String?
    @State private var broadcastPicker: RPSystemBroadcastPickerView = {
        let picker = RPSystemBroadcastPickerView(
            frame: CGRect(x: 0, y: 0, width: 44, height: 44)
        )
        picker.preferredExtension = "com.tddworks.baguette.twin.broadcast"
        picker.showsMicrophoneButton = false
        return picker
    }()

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
                    Button(saved ? "Saved" : "Save") { save() }
                    // The broadcast extension cannot trigger iOS's
                    // Local Network permission prompt — only the app
                    // can. This probe is what makes the prompt appear;
                    // without it the extension's socket dies silently.
                    Button("Test connection") { Task { await testConnection() } }
                    if let probe {
                        Text(probe)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("mirror") {
                    Button {
                        triggerBroadcastPicker()
                    } label: {
                        Label("Start broadcast", systemImage: "record.circle")
                    }
                    .background(
                        // The system picker must be in the hierarchy for
                        // its button to fire, but it draws invisibly on a
                        // Form row — so it lives here at 1 pt and our own
                        // button forwards the tap.
                        BroadcastPickerHost(picker: broadcastPicker)
                            .frame(width: 1, height: 1)
                            .opacity(0.02)
                    )
                    Text("Save the host, test the connection (accept the Local Network prompt), then start the broadcast. The mirror appears at http://\(endpoint)/devices.json and streams from /devices/<id>/stream.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Baguette Twin")
            .onChange(of: endpoint) { saved = false }
        }
    }

    private func save() {
        let normalized = TwinWire.normalizedEndpoint(endpoint)
        endpoint = normalized
        defaults?.set(normalized, forKey: TwinWire.endpointKey)
        if defaults?.string(forKey: TwinWire.deviceIdKey) == nil {
            defaults?.set(
                UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString,
                forKey: TwinWire.deviceIdKey
            )
        }
        saved = true
    }

    /// Forward our visible button's tap to the system picker's
    /// internal button (searched recursively — its hierarchy is not
    /// documented and has moved between iOS releases).
    private func triggerBroadcastPicker() {
        func firstButton(in view: UIView) -> UIButton? {
            for subview in view.subviews {
                if let button = subview as? UIButton { return button }
                if let nested = firstButton(in: subview) { return nested }
            }
            return nil
        }
        if let button = firstButton(in: broadcastPicker) {
            button.sendActions(for: .touchUpInside)
        } else {
            probe = "broadcast picker button not found — is the extension installed?"
        }
    }

    private func testConnection() async {
        save()
        probe = "connecting…"
        guard let url = URL(string: "http://\(TwinWire.normalizedEndpoint(endpoint))/devices.json") else {
            probe = "invalid address"
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            probe = "baguette answered: \(String(decoding: data, as: UTF8.self).prefix(120))"
        } catch {
            probe = "unreachable: \(error.localizedDescription)"
        }
    }
}

/// Hosts the one shared `RPSystemBroadcastPickerView` instance inside
/// the hierarchy; the visible SwiftUI button forwards taps into it.
struct BroadcastPickerHost: UIViewRepresentable {
    let picker: RPSystemBroadcastPickerView

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        picker
    }

    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}
}
