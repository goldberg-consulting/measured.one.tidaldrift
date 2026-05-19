import Foundation

// MARK: - Remote App Info (for client to display available apps from host)

/// Lightweight version of StreamableApp for network transmission
struct RemoteAppInfo: Codable, Identifiable {
    let processID: Int32
    let name: String
    let bundleIdentifier: String?
    let windows: [RemoteWindowInfo]
    
    var id: Int32 { processID }
}

struct RemoteWindowInfo: Codable, Identifiable {
    let windowID: UInt32
    let title: String
    let width: Int
    let height: Int
    let isOnScreen: Bool
    
    var id: UInt32 { windowID }
}

/// Request to stream a specific app or window
struct StreamRequest: Codable {
    enum StreamType: String, Codable {
        case fullDisplay
        case window
        case app
    }
    
    let type: StreamType
    let processID: Int32?    // For app streaming
    let windowID: UInt32?    // For window streaming
    let appName: String?     // Human-readable name
}

/// Response to a stream request
struct StreamResponse: Codable {
    let success: Bool
    let message: String?
    let streamingTarget: String?  // What is being streamed
}
