import AppKit
import SwiftUI

/// Closing the window stops accepting new network offers. Outgoing copies keep
/// their queue, so reopening the window shows the actual state of each drop.
@MainActor
final class TidalTransferWindow: NSObject, NSWindowDelegate {
    static let shared = TidalTransferWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let queue = TidalTransferQueue { sources, destination, progress in
                try await TidalTransferService.copy(sources, to: destination, progress: progress)
            }
            let view = TidalTransferView(queue: queue).environmentObject(AppState.shared)
            let newWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 630),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                     backing: .buffered, defer: false)
            newWindow.title = "Tidal Transfer"
            newWindow.contentView = NSHostingView(rootView: view)
            newWindow.contentMinSize = NSSize(width: 430, height: 500)
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
            newWindow.center()
            newWindow.setFrameAutosaveName("TidalTransferWindow")
            window = newWindow
        }
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        TidalTransferInbox.shared.enabled = false
    }
}

@MainActor
private struct TidalTransferView: View {
    @ObservedObject var queue: TidalTransferQueue
    @ObservedObject private var inbox = TidalTransferInbox.shared
    @EnvironmentObject private var appState: AppState
    @State private var destination: TidalTransferDestination?
    @State private var stagedDrops: [[URL]] = []
    @State private var isTargeted = false

    private var peers: [DiscoveredDevice] {
        appState.discoveredDevices
            .filter { $0.services.contains(.tidalDrop) && !$0.isCurrentDevice && !$0.isStale }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 25))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tidal Transfer").font(.title2.weight(.semibold))
                    Text("Copy files and folders to a Mac or a mounted share.").foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Copy to").font(.caption).foregroundStyle(.secondary)
                    Text(destination?.name ?? "Choose a destination").font(.headline)
                    if let destination {
                        Text(destination.detail).lineLimit(1).truncationMode(.middle)
                            .font(.caption).foregroundStyle(.secondary).help(destination.detail)
                    }
                }
                Spacer(minLength: 12)
                destinationMenu
            }
            dropZone
            if !stagedDrops.isEmpty {
                HStack {
                    Text("Choose a destination to copy \(stagedDrops.reduce(0) { $0 + $1.count }) selected items.")
                        .font(.callout)
                    Spacer()
                    Button("Discard selection") { stagedDrops.removeAll() }
                }
            }
            Divider()
            activity
            Divider()
            receiving
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var destinationMenu: some View {
        Menu {
            Button("Choose Folder or Mounted Share…") { pickDestinationFolder() }
            Divider()
            Section("Nearby Macs") {
                if peers.isEmpty {
                    Text("No TidalDrift peers found")
                }
                ForEach(peers) { device in
                    Button("\(device.displayName) (\(device.ipAddress))") { select(.peer(device)) }
                }
            }
        } label: { Label("Destination", systemImage: "arrow.turn.down.right") }
        .fixedSize()
        .help("Choose a folder in Finder or a Mac running Tidal Transfer.")
        .accessibilityLabel("Choose transfer destination")
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color.accentColor.opacity(isTargeted ? 0.15 : 0.04))
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(Color.accentColor.opacity(isTargeted ? 0.9 : 0.55),
                                  style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6, 5]))
                VStack(spacing: 5) {
                    Image(systemName: "tray.and.arrow.down").font(.title)
                        .foregroundStyle(.tint).accessibilityHidden(true)
                    Text("Drop files or folders here").font(.headline)
                }
                TransferFinderDrop(onHighlight: { isTargeted = $0 }, onDrop: add)
            }
            .frame(height: 90)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Drop files or folders here")
            HStack(alignment: .firstTextBaseline) {
                Text("For Mac-to-Mac copies, open Tidal Transfer on both Macs and enable receiving on the destination.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Choose Files…") { pickSources() }
                    .accessibilityLabel("Choose files or folders to copy")
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                if queue.batches.contains(where: { $0.state.isFinal }) {
                    Button("Clear Finished") { queue.clearFinished() }
                        .buttonStyle(.link)
                        .accessibilityLabel("Clear finished transfers")
                }
            }
            if queue.batches.isEmpty {
                Text("Your copies will appear here.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(queue.activity) { batch in
                            TransferBatchRow(batch: batch, cancel: { queue.cancel(batch.id) })
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var receiving: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Allow incoming Tidal Transfer batches", isOn: $inbox.enabled).toggleStyle(.switch)
                .accessibilityHint("You approve each incoming batch while this window is open.")
            if inbox.enabled {
                Text("Save to \(appState.settings.tidalDropFolder.path)")
                    .lineLimit(1).truncationMode(.middle).help(appState.settings.tidalDropFolder.path)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Use a trusted local network. Transfers between Macs are unencrypted.")
                .font(.caption).foregroundStyle(.secondary)
            if let offer = inbox.offer {
                HStack {
                    Text("\(offer.peer) would like to send \(offer.count) items (\(ByteCountFormatter.string(fromByteCount: offer.bytes, countStyle: .file))).")
                        .font(.callout)
                    Spacer()
                    Button("Decline") { if inbox.offer?.id == offer.id { inbox.respond(accept: false) } }
                    Button("Accept") { if inbox.offer?.id == offer.id { inbox.respond(accept: true) } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 2)
            }
            if let status = inbox.status { Text(status).font(.callout).textSelection(.enabled) }
        }
    }

    private func add(_ urls: [URL]) {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return }
        if let destination {
            queue.enqueue(urls, to: destination)
        } else {
            stagedDrops.append(urls)
        }
    }

    private func select(_ target: TidalTransferDestination) {
        destination = target
        for drop in stagedDrops { queue.enqueue(drop, to: target) }
        stagedDrops.removeAll()
    }

    private func pickSources() {
        let panel = NSOpenPanel()
        panel.title = "Choose files or folders to copy"
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        present(panel) { if $0 == .OK { add(panel.urls) } }
    }

    private func pickDestinationFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a destination folder or mounted share"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        present(panel) { if $0 == .OK, let url = panel.url { select(.folder(url)) } }
    }

    private func present(_ panel: NSOpenPanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}

private struct TransferBatchRow: View {
    let batch: TidalTransferQueue.Batch
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(batch.title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text("To \(batch.destination)").font(.caption).foregroundStyle(.secondary)
                switch batch.state {
                case .queued: Text("Queued").foregroundStyle(.secondary)
                case .copying(let detail, let fraction):
                    if let fraction {
                        ProgressView(value: fraction)
                            .accessibilityLabel("Copy progress for \(batch.title)")
                    }
                    Text(detail).font(.caption)
                case .stopping: Text("Stopping…")
                case .finished: Label("Copied", systemImage: "checkmark.circle")
                case .cancelled: Text("Cancelled")
                case .failed(let reason): Text(reason).textSelection(.enabled)
                }
            }
            Spacer()
            if batch.state.canCancel {
                Button("Cancel", action: cancel).accessibilityLabel("Cancel copying \(batch.title)")
            }
        }
        .padding(.vertical, 4)
    }
}

/// Ask Finder for file URLs only. Loading item data from the pasteboard would
/// read the entire payload before a transfer, which can exhaust RAM on large drops.
private struct TransferFinderDrop: NSViewRepresentable {
    let onHighlight: (Bool) -> Void
    let onDrop: ([URL]) -> Void

    final class Target: NSView {
        var highlight: (Bool) -> Void = { _ in }
        var receive: ([URL]) -> Void = { _ in }
        private let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            let allowed = sender.draggingSourceOperationMask.contains(.copy)
                && sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: options)
            highlight(allowed)
            return allowed ? .copy : []
        }

        override func draggingExited(_ sender: NSDraggingInfo?) { highlight(false) }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            highlight(false)
            let urls = TransferFinderPasteboard.fileURLs(from: sender.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            receive(urls)
            return true
        }
    }

    func makeNSView(context: Context) -> Target {
        let view = Target()
        view.registerForDraggedTypes([.fileURL])
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: Target, context: Context) {
        view.highlight = onHighlight
        view.receive = onDrop
    }
}

enum TransferFinderPasteboard {
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).filter(\.isFileURL)
    }
}
