import Foundation
import Network

enum TidalTransferService {
    typealias Progress = @Sendable (String, Double?) async -> Void

    static func copy(_ sources: [URL], to destination: TidalTransferDestination,
                     progress: @escaping Progress) async throws {
        let scopes = sources.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in scopes { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        switch destination {
        case .folder(let url):
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            await progress("Preparing the copy…", nil)
            let (updates, continuation) = AsyncStream<(String, Double?)>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let relay = Task { for await (text, fraction) in updates { await progress(text, fraction) } }
            let throttle = TidalTransferByteUpdates()
            do {
                _ = try await TidalTransferFolderCopy.copy(sources, to: url) { value in
                    guard throttle.shouldReport() else { return }
                    let fraction = value.totalBytes > 0 ? Double(value.bytesCopied) / Double(value.totalBytes)
                        : Double(value.completedItems) / Double(max(1, value.totalItems))
                    continuation.yield(("Copying " + (value.currentName ?? "items") + "…", min(1, fraction)))
                }
            } catch {
                continuation.finish()
                await relay.value
                throw error
            }
            continuation.finish()
            await relay.value
        case .peer(let device):
            await progress("Preparing the batch…", nil)
            let plan = try TidalTransferBatch.plan(sources)
            // Use only the address displayed. A cached DHCP address can now belong to another Mac.
            let address = try selectedAddress(for: device)
            await progress("Connecting to \(device.displayName)…", nil)
            let channel = TidalTransferChannel(NWConnection(host: .init(address), port: 5902, using: .tcp))
            defer { channel.cancel() }
            do {
                try await withTaskCancellationHandler {
                    try await channel.connect()
                    try await channel.send(plan: plan, status: progress)
                } onCancel: { channel.cancel() }
            } catch let error as TidalTransferChannel.Unconfirmed {
                throw error
            } catch {
                try Task.checkCancellation()
                throw error
            }
        }
    }

    static func selectedAddress(for device: DiscoveredDevice) throws -> String {
        guard NetworkUtils.isLocalPeerAddress(device.ipAddress) else {
            throw TidalTransferChannel.Failure("Choose a Mac with a local network address.")
        }
        return device.ipAddress
    }
}
