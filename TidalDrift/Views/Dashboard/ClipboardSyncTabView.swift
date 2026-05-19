import SwiftUI

struct ClipboardSyncTabView: View {
    @ObservedObject private var clipboardService = ClipboardSyncService.shared
    
    private func toggleSync(_ enabled: Bool) {
        if enabled {
            clipboardService.isEnabled = true
        } else {
            clipboardService.isEnabled = false
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                
                statusSection
                
                if clipboardService.isEnabled {
                    enabledContent
                } else {
                    disabledContent
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "doc.on.clipboard")
                        .font(.largeTitle)
                        .foregroundColor(.blue)
                    
                    Text("Clipboard Sync")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                }
                
                Text("Share your clipboard between Macs running TidalDrift")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
    
    private var statusSection: some View {
        HStack(spacing: 16) {
            Toggle("Enable Clipboard Sync", isOn: $clipboardService.isEnabled)
                .toggleStyle(.switch)
            
            Spacer()
            
            if clipboardService.isEnabled {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Active")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
    
    private var disabledContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 48))
                .foregroundColor(.blue)
            
            Text("Sync your clipboard across Macs")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("When enabled, anything you copy on one Mac will be available to paste on other Macs running TidalDrift on the same network.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("How it works:")
                    .font(.headline)
                
                BulletPoint(text: "Uses Bonjour to find other TidalDrift instances", done: true)
                BulletPoint(text: "Syncs text content automatically", done: true)
                BulletPoint(text: "Works on your local network only", done: true)
                BulletPoint(text: "Image and file sync", done: false)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.1)))
            
            Text("Toggle the switch above to start syncing.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
    
    private var enabledContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Connected Macs
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Connected Macs")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Spacer()
                    
                    Text("\(clipboardService.connectedPeers.count) connected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if clipboardService.connectedPeers.isEmpty {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        Text("Looking for other Macs running TidalDrift...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 12)
                    ], spacing: 12) {
                        ForEach(clipboardService.connectedPeers, id: \.self) { peerName in
                            SimplePeerCard(peerName: peerName)
                        }
                    }
                }
            }
            
            // Clipboard history
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent Clipboard Items")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                if clipboardService.clipboardHistory.isEmpty {
                    Text("No clipboard activity yet")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    VStack(spacing: 8) {
                        ForEach(clipboardService.clipboardHistory.prefix(10)) { item in
                            ClipboardHistoryRow(item: item)
                        }
                    }
                }
            }
            
            // Info note
            VStack(alignment: .leading, spacing: 8) {
                Label("Privacy Note", systemImage: "lock.shield")
                    .font(.headline)
                    .foregroundColor(.blue)
                
                Text("Clipboard data is only shared with other Macs on your local network running TidalDrift. It's not sent to any external servers.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.1)))
        }
    }
}

struct SimplePeerCard: View {
    let peerName: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundColor(.accentColor)
            
            Text(peerName)
                .font(.subheadline)
                .fontWeight(.medium)
            
            Spacer()
            
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

struct ClipboardHistoryRow: View {
    let item: ClipboardItem
    
    private var icon: String {
        switch item.contentType {
        case .text: return "doc.text"
        case .image: return "photo"
        case .file: return "doc"
        case .rtf: return "doc.richtext"
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview)
                    .font(.subheadline)
                    .lineLimit(1)
                
                HStack {
                    Text("From \(item.sourceDevice)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .foregroundColor(.secondary)
                    
                    Text(item.relativeTime)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct ClipboardSyncTabView_Previews: PreviewProvider {
    static var previews: some View {
        ClipboardSyncTabView()
    }
}

