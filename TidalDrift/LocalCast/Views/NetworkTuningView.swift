import SwiftUI

/// Saved settings are applied on host start, never by interrupting a live stream.
struct NetworkTuningView: View {
    @AppStorage("localCastNetworkTuning") private var enabled = false
    @AppStorage("localCastNetworkAdaptive") private var adaptive = true
    @AppStorage("localCastNetworkRate") private var rate = 500
    @AppStorage("localCastNetworkBurst") private var burst = 16
    @AppStorage("localCastNetworkQueue") private var queueMilliseconds = 100
    @AppStorage("localCastNetworkDiagnostics") private var diagnostics = false
    @ObservedObject private var service = LocalCastService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Network tuning").font(.subheadline).foregroundStyle(.secondary)
            Toggle("Smooth outgoing traffic", isOn: $enabled)
            Text("An optional way to spread video traffic more evenly. Leave it off to use the current sending behavior.")
                .font(.caption).foregroundStyle(.secondary)
            if enabled {
                Picker("Sending limit", selection: $rate) {
                    ForEach([100, 250, 500, 1000, 2500, 10_000], id: \.self) { value in
                        Text("\(value) Mbps").tag(value)
                    }
                }
                Text("Choose a limit above your video bitrate and below your connection's measured speed. This does not change picture quality settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Burst size", selection: $burst) {
                    Text("Small · 8 KB").tag(8)
                    Text("Balanced · 16 KB").tag(16)
                    Text("Large · 32 KB").tag(32)
                    Text("Largest · 64 KB").tag(64)
                }
                Picker("Backlog allowance", selection: $queueMilliseconds) {
                    ForEach([50, 100, 200, 500], id: \.self) { value in
                        Text("\(value) ms").tag(value)
                    }
                }
                Text("Limits waiting video. A large individual frame may take longer to send.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Adjust sending speed automatically", isOn: $adaptive)
                Text("Eases the sending speed when the viewer reports incomplete frames, then gradually returns toward your limit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Collect connection details", isOn: $diagnostics)
            Text("Adds optional send and playback counters. No pop-ups. Collecting details adds some processing work.")
                .font(.caption).foregroundStyle(.secondary)
            if diagnostics {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if let details = service.networkDiagnostics {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Since hosting started")
                            Text("Observed sends: \(details.datagrams)")
                            Text("Local send failures: \(details.localSendFailures)")
                            Text("Media skipped to limit backlog: \(details.skippedMedia)")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Applies the next time hosting starts. On the viewer, reconnect to apply connection details.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Reset network tuning") {
                enabled = false
                adaptive = true
                rate = 500
                burst = 16
                diagnostics = false
                queueMilliseconds = 100
            }
            .controlSize(.small)
        }
        .padding(.leading, 8)
    }
}
