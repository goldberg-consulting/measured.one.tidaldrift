import Foundation
import Network
import SwiftUI
import UserNotifications

/// Protocol-agnostic transfer status
enum TidalDropStatus: Equatable {
    case pending
    case transferring
    case completed
    case failed(String)
    
    var isTransferring: Bool {
        if case .transferring = self { return true }
        return false
    }
}

/// Handles peer-to-peer file transfers over the TidalDrop protocol
/// Also supports fallback to mounted SMB/AFP shares
class TidalDropService: ObservableObject {
    static let shared = TidalDropService()
    
    @Published var activeTransfers: [UUID: DropTransfer] = [:]
    @Published var isListening = false
    
    struct DropTransfer: Identifiable {
        let id: UUID
        let fileName: String
        let fileSize: Int64
        var progress: Double
        let isIncoming: Bool
        var status: TidalDropStatus
        let remoteEndpoint: String
    }
    
    struct FileMetadata: Codable {
        let fileName: String
        let fileSize: Int64
    }
    
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.tidaldrift.drop", qos: .userInitiated)
    
    // Store active connections to prevent premature deallocation
    private var activeConnections: [UUID: NWConnection] = [:]
    private var incomingConnections: [UUID: NWConnection] = [:]
    private let connectionsLock = NSLock()
    
    private init() {
        ensureDestinationFolderExists()
        startListening()
        requestNotificationPermission()
    }
    
    private func ensureDestinationFolderExists() {
        let folder = AppState.shared.settings.tidalDropFolder
        if !FileManager.default.fileExists(atPath: folder.path) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                print("✅ TidalDrop: Created default destination folder at \(folder.path)")
            } catch {
                print("❌ TidalDrop: Failed to create initial destination folder: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Smart Drop (tries mounted drives first)
    
    /// Sends a file using the best available method:
    /// 1. If target has a mounted share, copies there directly
    /// 2. Otherwise uses peer-to-peer TidalDrop protocol
    func smartSendFile(at url: URL, to device: DiscoveredDevice) {
        print("🌊 TidalDrop: Smart send - checking for mounted shares for \(device.name)")
        
        if let mountedPath = findMountedShare(for: device) {
            print("🌊 TidalDrop: Found mounted share: \(mountedPath)")
            copyToMountedShare(file: url, destination: mountedPath, device: device)
        } else {
            print("🌊 TidalDrop: No mounted share, using peer-to-peer")
            sendFile(at: url, to: device.ipAddress)
        }
    }
    
    /// Sends pre-read file data. Use this when the caller has already read the
    /// file (e.g. while security-scoped access was still active from a drag & drop).
    func smartSendFileData(fileName: String, fileData: Data, to device: DiscoveredDevice) {
        print("🌊 TidalDrop: Smart send (data) '\(fileName)' (\(fileData.count) bytes) to \(device.name)")
        
        if let mountedPath = findMountedShare(for: device) {
            let destination = resolveDropDestination(within: mountedPath)
            let destinationFile = destination.appendingPathComponent(fileName)
            
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    if FileManager.default.fileExists(atPath: destinationFile.path) {
                        try FileManager.default.removeItem(at: destinationFile)
                    }
                    try fileData.write(to: destinationFile)
                    print("✅ TidalDrop: Wrote '\(fileName)' to mounted share")
                    self.notifyCompletion(fileName: fileName, isIncoming: false, viaMountedShare: true)
                } catch {
                    print("TidalDrop: Mounted share write failed, using peer-to-peer: \(error)")
                    self.sendFileWithData(fileName: fileName, fileData: fileData, to: device.ipAddress)
                }
            }
        } else {
            sendFileWithData(fileName: fileName, fileData: fileData, to: device.ipAddress)
        }
    }
    
    /// Finds a mounted network share that belongs to the target device
    private func findMountedShare(for device: DiscoveredDevice) -> URL? {
        let volumesPath = URL(fileURLWithPath: "/Volumes")
        
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: volumesPath,
            includingPropertiesForKeys: [.volumeIsRemovableKey, .volumeURLForRemountingKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        
        // Look for network volumes that might match the device
        for volumeURL in contents {
            // Check if it's a network volume
            if let remountURL = try? volumeURL.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting,
               let host = remountURL.host {
                // Match by IP address or hostname
                let hostLower = host.lowercased()
                let deviceHost = device.hostname.lowercased().replacingOccurrences(of: ".local", with: "")
                let deviceName = device.name.lowercased()
                
                if host == device.ipAddress ||
                   hostLower == deviceHost ||
                   hostLower.contains(deviceName) ||
                   deviceName.contains(hostLower) {
                    print("🌊 TidalDrop: Matched volume \(volumeURL.lastPathComponent) to device \(device.name)")
                    return volumeURL
                }
            }
        }
        
        return nil
    }
    
    /// Resolves the best subfolder within a mounted share for TidalDrop files.
    /// Prefers `Public/Drop Box` (matches macOS convention and the peer-to-peer
    /// receiver path), falling back to `Public/`, then the share root.
    private func resolveDropDestination(within shareRoot: URL) -> URL {
        let fm = FileManager.default
        
        // Best: Public/Drop Box (standard macOS incoming files folder)
        let dropBox = shareRoot.appendingPathComponent("Public").appendingPathComponent("Drop Box")
        if fm.fileExists(atPath: dropBox.path) {
            print("🌊 TidalDrop: Using Public/Drop Box within mounted share")
            return dropBox
        }
        
        // Try to create it if Public exists
        let publicDir = shareRoot.appendingPathComponent("Public")
        if fm.fileExists(atPath: publicDir.path) {
            do {
                try fm.createDirectory(at: dropBox, withIntermediateDirectories: true)
                print("🌊 TidalDrop: Created Public/Drop Box within mounted share")
                return dropBox
            } catch {
                print("🌊 TidalDrop: Could not create Drop Box, using Public/")
                return publicDir
            }
        }
        
        // Fallback: share root (original behavior)
        print("🌊 TidalDrop: No Public folder found, using share root")
        return shareRoot
    }
    
    /// Copies a file to a mounted network share
    private func copyToMountedShare(file: URL, destination: URL, device: DiscoveredDevice) {
        let transferId = UUID()
        let fileName = file.lastPathComponent
        
        // Start security-scoped access for the source file (required for sandboxed files)
        let didStartAccess = file.startAccessingSecurityScopedResource()
        
        let fileSize = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        
        // Resolve the best subfolder within the share (Public/Drop Box > Public > root)
        let resolvedDestination = resolveDropDestination(within: destination)
        
        print("🌊 TidalDrop: Attempting copy")
        print("   Source: \(file.path)")
        print("   Share root: \(destination.path)")
        print("   Resolved destination: \(resolvedDestination.path)")
        print("   File: \(fileName) (\(fileSize) bytes)")
        print("   Security scoped access: \(didStartAccess)")
        
        // Check if destination is writable
        let isWritable = FileManager.default.isWritableFile(atPath: resolvedDestination.path)
        print("   Destination writable: \(isWritable)")
        
        if !isWritable {
            print("❌ TidalDrop: Destination not writable, falling back to peer-to-peer")
            if didStartAccess { file.stopAccessingSecurityScopedResource() }
            
            // Fallback to peer-to-peer
            sendFile(at: file, to: device.ipAddress)
            return
        }
        
        // Read file data while we have security access
        guard let fileData = try? Data(contentsOf: file) else {
            print("❌ TidalDrop: Cannot read source file, falling back to peer-to-peer")
            if didStartAccess { file.stopAccessingSecurityScopedResource() }
            sendFile(at: file, to: device.ipAddress)
            return
        }
        
        // Stop security access - we have the data now
        if didStartAccess { file.stopAccessingSecurityScopedResource() }
        
        let transfer = DropTransfer(
            id: transferId,
            fileName: fileName,
            fileSize: Int64(fileData.count),
            progress: 0,
            isIncoming: false,
            status: .transferring,
            remoteEndpoint: device.ipAddress
        )
        
        DispatchQueue.main.async {
            self.activeTransfers[transferId] = transfer
        }
        
        // Perform write on background queue
        DispatchQueue.global(qos: .userInitiated).async {
            let destinationFile = resolvedDestination.appendingPathComponent(fileName)
            
            print("🌊 TidalDrop: Writing to: \(destinationFile.path)")
            
            // Handle existing file
            if FileManager.default.fileExists(atPath: destinationFile.path) {
                do {
                    try FileManager.default.removeItem(at: destinationFile)
                    print("🌊 TidalDrop: Removed existing file")
                } catch {
                    print("⚠️ TidalDrop: Could not remove existing file: \(error)")
                }
            }
            
            do {
                // Write data directly instead of copyItem (avoids security scope issues)
                try fileData.write(to: destinationFile)
                
                print("✅ TidalDrop: Successfully wrote to mounted share: \(destinationFile.path)")
                
                DispatchQueue.main.async {
                    self.activeTransfers[transferId]?.progress = 1.0
                    self.activeTransfers[transferId]?.status = .completed
                }
                
                self.notifyCompletion(fileName: fileName, isIncoming: false, viaMountedShare: true)
            } catch let error as NSError {
                print("❌ TidalDrop: Failed to write to mounted share")
                print("   Error domain: \(error.domain)")
                print("   Error code: \(error.code)")
                print("   Error: \(error.localizedDescription)")
                
                if error.domain == NSCocoaErrorDomain && (error.code == 513 || error.code == 4) {
                    // Permission denied or file not found - common with network shares
                    print("🌊 TidalDrop: Permission issue, falling back to peer-to-peer")
                    
                    DispatchQueue.main.async {
                        self.activeTransfers.removeValue(forKey: transferId)
                    }
                    
                    // Try peer-to-peer as fallback
                    self.sendFileWithData(fileName: fileName, fileData: fileData, to: device.ipAddress)
                } else {
                    DispatchQueue.main.async {
                        self.activeTransfers[transferId]?.status = .failed("Copy failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    /// Send file using pre-loaded data (used as fallback)
    private func sendFileWithData(fileName: String, fileData: Data, to ipAddress: String) {
        print("🌊 TidalDrop: Peer-to-peer fallback for \(fileName)")
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(ipAddress), port: 5902)
        
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 10
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        
        let connection = NWConnection(to: endpoint, using: params)
        let transferId = UUID()
        let connectionId = UUID()
        
        // Store connection to prevent premature deallocation
        connectionsLock.lock()
        activeConnections[connectionId] = connection
        connectionsLock.unlock()
        
        let transfer = DropTransfer(
            id: transferId,
            fileName: fileName,
            fileSize: Int64(fileData.count),
            progress: 0,
            isIncoming: false,
            status: .pending,
            remoteEndpoint: ipAddress
        )
        
        DispatchQueue.main.async {
            self.activeTransfers[transferId] = transfer
        }
        
        var didConnect = false
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                didConnect = true
                self?.performSendWithData(connection, transferId: transferId, name: fileName, size: Int64(fileData.count), fileData: fileData, connectionId: connectionId)
            case .failed(let error):
                print("❌ TidalDrop: Fallback connection failed: \(error)")
                self?.cleanupConnection(id: connectionId)
                DispatchQueue.main.async {
                    self?.activeTransfers[transferId]?.status = .failed("Connection failed: \(error.localizedDescription)")
                }
            case .cancelled:
                self?.connectionsLock.lock()
                self?.activeConnections.removeValue(forKey: connectionId)
                self?.connectionsLock.unlock()
            default:
                break
            }
        }
        
        connection.start(queue: queue)
        
        queue.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            guard !didConnect else { return }
            self?.cleanupConnection(id: connectionId)
            DispatchQueue.main.async {
                self?.activeTransfers[transferId]?.status = .failed("Connection timeout")
            }
        }
    }
    
    private func cleanupConnection(id: UUID) {
        connectionsLock.lock()
        if let connection = activeConnections[id] {
            connection.cancel()
        }
        connectionsLock.unlock()
    }
    
    private func notifyCompletion(fileName: String, isIncoming: Bool, viaMountedShare: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = isIncoming ? "TidalDrop Received" : "TidalDrop Sent"
        
        if viaMountedShare {
            content.body = "'\(fileName)' copied to shared folder"
        } else {
            let folderName = AppState.shared.settings.tidalDropFolder.lastPathComponent
            content.body = isIncoming ? "'\(fileName)' saved to \(folderName)" : "'\(fileName)' sent successfully"
        }
        
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("⚠️ TidalDrop: Failed to send completion notification: \(error.localizedDescription)")
            }
        }
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                print("✅ TidalDrop: Notification permission granted")
            } else if let error = error {
                print("❌ TidalDrop: Notification permission error: \(error.localizedDescription)")
            } else {
                print("⚠️ TidalDrop: Notification permission denied")
            }
        }
    }
    
    func startListening() {
        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params, on: 5902)
            
            // Advertise the service via Bonjour so other TidalDrift instances can find it
            let name = NetworkUtils.sanitizedComputerName
            listener?.service = NWListener.Service(name: name, type: "_tidaldrop._tcp")
            
            listener?.stateUpdateHandler = { [weak self] state in
                print("🌊 TidalDrop: Listener state: \(state)")
                switch state {
                case .ready:
                    DispatchQueue.main.async {
                        self?.isListening = true
                    }
                    print("✅ TidalDrop: Listener READY on port 5902")
                case .failed(let error):
                    print("❌ TidalDrop: Listener FAILED: \(error)")
                    DispatchQueue.main.async {
                        self?.isListening = false
                    }
                case .cancelled:
                    print("🌊 TidalDrop: Listener cancelled")
                    DispatchQueue.main.async {
                        self?.isListening = false
                    }
                default:
                    break
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                print("🌊 TidalDrop: *** INCOMING CONNECTION from \(connection.endpoint) ***")
                self?.handleIncomingConnection(connection)
            }
            
            listener?.start(queue: queue)
            print("🌊 TidalDrop: Starting listener on port 5902...")
        } catch {
            print("❌ TidalDrop: Listener creation failed: \(error)")
        }
    }
    
    func stopListening() {
        listener?.cancel()
        listener = nil
        
        connectionsLock.lock()
        activeConnections.values.forEach { $0.cancel() }
        activeConnections.removeAll()
        incomingConnections.values.forEach { $0.cancel() }
        incomingConnections.removeAll()
        connectionsLock.unlock()
        
        DispatchQueue.main.async { [weak self] in
            self?.isListening = false
        }
    }
    
    private func handleIncomingConnection(_ connection: NWConnection) {
        let connID = UUID()
        connectionsLock.lock()
        incomingConnections[connID] = connection
        connectionsLock.unlock()
        
        print("🌊 TidalDrop: Handling incoming connection from \(connection.endpoint)")
        
        // Extract remote IP for matching in UI
        let remoteIP: String
        if case .hostPort(let host, _) = connection.endpoint {
            let hostStr = "\(host)"
            if let percentIndex = hostStr.firstIndex(of: "%") {
                remoteIP = String(hostStr[..<percentIndex])
            } else {
                remoteIP = hostStr
            }
        } else {
            remoteIP = "\(connection.endpoint)"
        }
        
        connection.stateUpdateHandler = { [weak self] state in
            print("🌊 TidalDrop: Incoming connection state: \(state)")
            if case .cancelled = state {
                self?.connectionsLock.lock()
                self?.incomingConnections.removeValue(forKey: connID)
                self?.connectionsLock.unlock()
            } else if case .failed = state {
                self?.connectionsLock.lock()
                self?.incomingConnections.removeValue(forKey: connID)
                self?.connectionsLock.unlock()
            }
        }
        
        connection.start(queue: queue)
        
        // 1. Receive metadata size (4 bytes)
        print("🌊 TidalDrop: Waiting for metadata size (4 bytes)...")
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            if let error = error {
                print("❌ TidalDrop: Error receiving metadata size: \(error)")
                return
            }
            guard let self = self, let d = data else {
                print("❌ TidalDrop: No data received for metadata size")
                return
            }
            
            let metadataSize = Int(d.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            
            guard metadataSize > 0 && metadataSize <= 1_048_576 else {
                print("❌ TidalDrop: Metadata size out of bounds: \(metadataSize)")
                connection.cancel()
                return
            }
            print("🌊 TidalDrop: Metadata size: \(metadataSize) bytes")
            
            // 2. Receive metadata JSON
            connection.receive(minimumIncompleteLength: metadataSize, maximumLength: metadataSize) { [weak self] data, _, _, error in
                if let error = error {
                    print("❌ TidalDrop: Error receiving metadata: \(error)")
                    return
                }
                guard let self = self, let d = data else {
                    print("❌ TidalDrop: No data received for metadata")
                    return
                }
                
                guard let metadata = try? JSONDecoder().decode(FileMetadata.self, from: d) else {
                    print("❌ TidalDrop: Failed to decode metadata JSON")
                    return
                }
                
                print("🌊 TidalDrop: Received metadata - File: \(metadata.fileName), Size: \(metadata.fileSize) bytes")
                self.setupIncomingTransfer(connection, metadata: metadata, remoteIP: remoteIP)
            }
        }
    }
    
    /// Sanitize a filename received from the network to prevent path traversal.
    private static func sanitizeFilename(_ raw: String) -> String? {
        let name = URL(fileURLWithPath: raw).lastPathComponent
        if name.isEmpty || name == "." || name == ".." { return nil }
        if name.hasPrefix(".") { return nil }
        return name
    }
    
    private func setupIncomingTransfer(_ connection: NWConnection, metadata: FileMetadata, remoteIP: String) {
        let transferId = UUID()
        let destinationFolder = AppState.shared.settings.tidalDropFolder
        let didStartDestinationAccess = destinationFolder.startAccessingSecurityScopedResource()
        
        guard let safeName = Self.sanitizeFilename(metadata.fileName) else {
            print("❌ TidalDrop: Rejected unsafe filename: \(metadata.fileName)")
            if didStartDestinationAccess {
                destinationFolder.stopAccessingSecurityScopedResource()
            }
            connection.cancel()
            return
        }
        
        print("🌊 TidalDrop: Setting up incoming transfer from \(remoteIP)")
        print("   Destination folder: \(destinationFolder.path)")
        
        // Create destination folder
        do {
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            print("✅ TidalDrop: Destination folder ready")
        } catch {
            print("❌ TidalDrop: Failed to create destination folder: \(error)")
        }
        
        let fileURL = destinationFolder.appendingPathComponent(safeName)
        print("   File will be saved to: \(fileURL.path)")
        
        let transfer = DropTransfer(
            id: transferId,
            fileName: metadata.fileName,
            fileSize: metadata.fileSize,
            progress: 0,
            isIncoming: true,
            status: .transferring,
            remoteEndpoint: remoteIP
        )
        
        DispatchQueue.main.async {
            self.activeTransfers[transferId] = transfer
            self.notifyTransferStarted(fileName: metadata.fileName, isIncoming: true)
            
            // Audible alert for recipient
            NSSound.beep()
        }
        
        // Remove existing file if present
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.removeItem(at: fileURL)
                print("🌊 TidalDrop: Removed existing file")
            } catch {
                print("⚠️ TidalDrop: Could not remove existing file: \(error)")
            }
        }
        
        // Create empty file
        let created = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        print("🌊 TidalDrop: Created empty file: \(created)")
        
        print("🌊 TidalDrop: Starting to receive file data...")
        receiveFileData(
            connection,
            transferId: transferId,
            fileURL: fileURL,
            fileSize: metadata.fileSize,
            receivedSoFar: 0,
            securityScopedDestination: didStartDestinationAccess ? destinationFolder : nil
        )
    }
    
    private func receiveFileData(
        _ connection: NWConnection,
        transferId: UUID,
        fileURL: URL,
        fileSize: Int64,
        receivedSoFar: Int64,
        securityScopedDestination: URL?
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let e = error {
                print("❌ TidalDrop: Error receiving file data: \(e)")
                securityScopedDestination?.stopAccessingSecurityScopedResource()
                DispatchQueue.main.async {
                    self.activeTransfers[transferId]?.status = .failed(e.localizedDescription)
                }
                return
            }
            
            if let d = data {
                // Write data to file
                do {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    handle.seekToEndOfFile()
                    handle.write(d)
                    try handle.close()
                } catch {
                    print("❌ TidalDrop: Error writing to file: \(error)")
                    securityScopedDestination?.stopAccessingSecurityScopedResource()
                    DispatchQueue.main.async {
                        self.activeTransfers[transferId]?.status = .failed("Write error: \(error.localizedDescription)")
                    }
                    return
                }
                
                let newReceived = receivedSoFar + Int64(d.count)
                let progress = Double(newReceived) / Double(fileSize)
                
                // Log progress every 10%
                let oldPercent = Int((Double(receivedSoFar) / Double(fileSize)) * 10)
                let newPercent = Int(progress * 10)
                if newPercent > oldPercent {
                    print("🌊 TidalDrop: Received \(newReceived)/\(fileSize) bytes (\(Int(progress * 100))%)")
                }
                
                DispatchQueue.main.async {
                    self.activeTransfers[transferId]?.progress = progress
                }
                
                if newReceived < fileSize {
                    self.receiveFileData(
                        connection,
                        transferId: transferId,
                        fileURL: fileURL,
                        fileSize: fileSize,
                        receivedSoFar: newReceived,
                        securityScopedDestination: securityScopedDestination
                    )
                } else {
                    print("✅ TidalDrop: File received completely! Saved to: \(fileURL.path)")
                    securityScopedDestination?.stopAccessingSecurityScopedResource()
                    self.completeTransfer(transferId: transferId, fileName: fileURL.lastPathComponent, isIncoming: true)
                    connection.cancel()
                }
            } else if isComplete {
                print("⚠️ TidalDrop: Connection completed but only received \(receivedSoFar)/\(fileSize) bytes")
                securityScopedDestination?.stopAccessingSecurityScopedResource()
            }
        }
    }
    
    func sendFile(at url: URL, to ipAddress: String) {
        print("🌊 TidalDrop: Initiating peer-to-peer send")
        print("   File: \(url.path)")
        print("   Target: \(ipAddress):5902")
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(ipAddress), port: 5902)
        let connection = NWConnection(to: endpoint, using: .tcp)
        let connectionId = UUID()
        
        // Store connection to prevent premature deallocation
        connectionsLock.lock()
        activeConnections[connectionId] = connection
        connectionsLock.unlock()
        
        let transferId = UUID()
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        
        print("   File size: \(size) bytes")
        
        let transfer = DropTransfer(
            id: transferId,
            fileName: name,
            fileSize: size,
            progress: 0,
            isIncoming: false,
            status: .pending,
            remoteEndpoint: ipAddress
        )
        
        DispatchQueue.main.async {
            self.activeTransfers[transferId] = transfer
            self.notifyTransferStarted(fileName: name, isIncoming: false)
        }
        
        connection.stateUpdateHandler = { [weak self] state in
            print("🌊 TidalDrop: Send connection state: \(state)")
            switch state {
            case .ready:
                print("✅ TidalDrop: Connection ready, starting transfer")
                self?.performSend(connection, transferId: transferId, url: url, name: name, size: size, connectionId: connectionId)
            case .failed(let error):
                print("❌ TidalDrop: Connection failed: \(error)")
                self?.cleanupConnection(id: connectionId)
                DispatchQueue.main.async {
                    self?.activeTransfers[transferId]?.status = .failed(error.localizedDescription)
                }
            case .cancelled:
                self?.connectionsLock.lock()
                self?.activeConnections.removeValue(forKey: connectionId)
                self?.connectionsLock.unlock()
            case .waiting(let error):
                print("⏳ TidalDrop: Connection waiting: \(error)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
    
    private func performSend(_ connection: NWConnection, transferId: UUID, url: URL, name: String, size: Int64, connectionId: UUID) {
        // Handle security-scoped access for sandboxed apps
        let didStartAccess = url.startAccessingSecurityScopedResource()
        print("🌊 TidalDrop: Security scoped access started: \(didStartAccess) for \(url.lastPathComponent)")
        
        // Read file data first
        let fileData: Data
        do {
            fileData = try Data(contentsOf: url)
            print("🌊 TidalDrop: Successfully read \(fileData.count) bytes from \(url.lastPathComponent)")
        } catch {
            print("❌ TidalDrop: Cannot read file for sending: \(error.localizedDescription)")
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            cleanupConnection(id: connectionId)
            DispatchQueue.main.async {
                self.activeTransfers[transferId]?.status = .failed("Cannot read file: \(error.localizedDescription)")
            }
            return
        }
        
        if didStartAccess { url.stopAccessingSecurityScopedResource() }
        
        performSendWithData(connection, transferId: transferId, name: name, size: size, fileData: fileData, connectionId: connectionId)
    }
    
    private func performSendWithData(_ connection: NWConnection, transferId: UUID, name: String, size: Int64, fileData: Data, connectionId: UUID) {
        DispatchQueue.main.async {
            self.activeTransfers[transferId]?.status = .transferring
        }
        
        let metadata = FileMetadata(fileName: name, fileSize: size)
        guard let metadataData = try? JSONEncoder().encode(metadata) else { return }
        
        var header = Data()
        let metadataSize = UInt32(metadataData.count).bigEndian
        header.append(Data([
            UInt8((metadataSize >> 24) & 0xFF),
            UInt8((metadataSize >> 16) & 0xFF),
            UInt8((metadataSize >> 8) & 0xFF),
            UInt8(metadataSize & 0xFF)
        ]))
        header.append(metadataData)
        
        print("🌊 TidalDrop: Sending header (\(header.count) bytes) + file (\(fileData.count) bytes)")
        
        connection.send(content: header, completion: .contentProcessed { [weak self] error in
            if let e = error {
                print("❌ TidalDrop: Header send failed: \(e)")
                self?.cleanupConnection(id: connectionId)
                DispatchQueue.main.async { self?.activeTransfers[transferId]?.status = .failed(e.localizedDescription) }
                return
            }
            
            connection.send(content: fileData, completion: .contentProcessed { [weak self] error in
                if let e = error {
                    print("❌ TidalDrop: File send failed: \(e)")
                    self?.cleanupConnection(id: connectionId)
                    DispatchQueue.main.async { self?.activeTransfers[transferId]?.status = .failed(e.localizedDescription) }
                } else {
                    print("✅ TidalDrop: File sent successfully!")
                    DispatchQueue.main.async { self?.activeTransfers[transferId]?.progress = 1.0 }
                    self?.completeTransfer(transferId: transferId, fileName: name, isIncoming: false)
                    self?.cleanupConnection(id: connectionId)
                }
            })
        })
    }
    
    private func completeTransfer(transferId: UUID, fileName: String, isIncoming: Bool) {
        DispatchQueue.main.async {
            self.activeTransfers[transferId]?.status = .completed
        }
        
        // Final notification
        let content = UNMutableNotificationContent()
        content.title = isIncoming ? "TidalDrop Received" : "TidalDrop Sent"
        let folderName = AppState.shared.settings.tidalDropFolder.lastPathComponent
        content.body = isIncoming ? "'\(fileName)' saved to \(folderName)" : "'\(fileName)' sent successfully"
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("⚠️ TidalDrop: Failed to send completion notification: \(error.localizedDescription)")
            }
        }
        
        // Auto-clear completed transfer after 10 seconds (increased from 5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            self.activeTransfers.removeValue(forKey: transferId)
        }
    }
    
    private func notifyTransferStarted(fileName: String, isIncoming: Bool) {
        let content = UNMutableNotificationContent()
        content.title = isIncoming ? "Incoming TidalDrop" : "Sending TidalDrop"
        content.body = isIncoming ? "Receiving '\(fileName)'..." : "Transferring '\(fileName)'..."
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("⚠️ TidalDrop: Failed to send start notification: \(error.localizedDescription)")
            }
        }
    }
}
