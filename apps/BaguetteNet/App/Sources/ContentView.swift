import SwiftUI
import BaguetteNetKit

struct ContentView: View {
    @EnvironmentObject private var controller: NetworkExtensionController

    // The three fields, plus a match-key text field. Bandwidth is edited
    // on a log scale; 0 = unlimited.
    @State private var bandwidthIndex: Double = 32   // 0…32, 32 = unlimited
    @State private var latencyMillis: Double = 0
    @State private var lossPercent: Double = 0
    @State private var matchKeysText: String = "SimDevice"
    @State private var preset: String = "unlimited"

    private var profile: NetworkProfile {
        NetworkProfile(
            bandwidthInBytes: Self.bandwidth(forIndex: bandwidthIndex),
            latencyMillis: Int(latencyMillis),
            packetLoss: lossPercent / 100.0
        )
    }

    private var matchKeys: [String] {
        matchKeysText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            GroupBox("Preset") {
                Picker("", selection: $preset) {
                    ForEach(["unlimited", "lte", "3g", "edge", "loss100", "airplane"], id: \.self) {
                        Text($0.uppercased()).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: preset) { _, name in applyPreset(name) }
            }

            GroupBox("Shape") {
                VStack(alignment: .leading, spacing: 12) {
                    slider("Bandwidth", value: $bandwidthIndex, range: 0...32,
                           readout: Self.bandwidthLabel(forIndex: bandwidthIndex))
                    slider("Latency", value: $latencyMillis, range: 0...2000,
                           readout: "\(Int(latencyMillis)) ms")
                    slider("Packet loss", value: $lossPercent, range: 0...100,
                           readout: "\(Int(lossPercent)) %")
                }
                .padding(.vertical, 4)
            }

            GroupBox("Target") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Match flows whose source identifier contains (comma-separated):")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("SimDevice", text: $matchKeysText)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Spacer()

            HStack {
                Button("Apply throttle") { controller.apply(profile, matchKeys: matchKeys) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.isFiltering && profile.isUnthrottled && controller.status != "Off")
                Button("Clear") { controller.clear() }
            }
        }
        .padding(20)
        .onChange(of: bandwidthIndex) { _, _ in preset = "custom" }
        .onChange(of: latencyMillis) { _, _ in preset = "custom" }
        .onChange(of: lossPercent) { _, _ in preset = "custom" }
    }

    private var header: some View {
        HStack {
            Image(systemName: "speedometer").font(.title2)
            VStack(alignment: .leading) {
                Text("Network Speed Control").font(.headline)
                Text(controller.status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Activate Extension") { controller.activate() }
        }
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, readout: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(readout).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func applyPreset(_ name: String) {
        guard let p = NetworkProfile.presets[name] else { return }
        bandwidthIndex = Self.index(forBandwidth: p.bandwidthInBytes)
        latencyMillis = Double(p.latencyMillis)
        lossPercent = p.packetLoss * 100
    }

    // MARK: - Log-scale bandwidth mapping (UI only)

    private static let minBytes = Double(4 * 1024), maxBytes = Double(50 * 1024 * 1024)

    static func bandwidth(forIndex idx: Double) -> UInt64 {
        if idx >= 32 { return 0 }
        let t = idx / 31
        return UInt64(exp(log(minBytes) + (log(maxBytes) - log(minBytes)) * t))
    }
    static func index(forBandwidth bytes: UInt64) -> Double {
        if bytes == 0 { return 32 }
        let t = (log(Double(bytes)) - log(minBytes)) / (log(maxBytes) - log(minBytes))
        return (t * 31).rounded()
    }
    static func bandwidthLabel(forIndex idx: Double) -> String {
        let b = bandwidth(forIndex: idx)
        if b == 0 { return "Unlimited" }
        if b >= 1024 * 1024 { return String(format: "%.1f MB/s", Double(b) / 1024 / 1024) }
        if b >= 1024 { return String(format: "%.0f KB/s", Double(b) / 1024) }
        return "\(b) B/s"
    }
}
