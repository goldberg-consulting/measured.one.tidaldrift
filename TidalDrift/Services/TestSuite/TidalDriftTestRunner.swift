import Foundation
import Combine
import OSLog

/// Result of a single test case
struct TestResult: Identifiable {
    let id = UUID()
    let name: String
    let category: String
    let passed: Bool
    let message: String
    let duration: TimeInterval
    let timestamp: Date = Date()
    
    var statusIcon: String {
        passed ? "checkmark.circle.fill" : "xmark.circle.fill"
    }
}

/// Overall status of the test runner
enum TestRunnerStatus: Equatable {
    case idle
    case running(current: String, progress: Double)
    case finished(passed: Int, failed: Int)
}

/// Orchestrates all integration tests across subsystems
@MainActor
class TidalDriftTestRunner: ObservableObject {
    static let shared = TidalDriftTestRunner()
    private let logger = Logger(subsystem: "com.tidaldrift", category: "TestRunner")
    
    @Published var results: [TestResult] = []
    @Published var status: TestRunnerStatus = .idle
    @Published var isRunning = false
    
    var passedCount: Int { results.filter(\.passed).count }
    var failedCount: Int { results.filter { !$0.passed }.count }
    
    private var allTests: [(String, String, () async -> (Bool, String))] = []
    
    private init() {}
    
    /// Run all tests
    func runAll() async {
        guard !isRunning else { return }
        isRunning = true
        results = []
        
        buildTestList()
        
        let total = allTests.count
        for (index, test) in allTests.enumerated() {
            let (name, category, testFn) = test
            status = .running(current: name, progress: Double(index) / Double(total))
            
            let start = Date()
            let (passed, message) = await testFn()
            let duration = Date().timeIntervalSince(start)
            
            let result = TestResult(
                name: name, category: category,
                passed: passed, message: message, duration: duration
            )
            results.append(result)
            
            logger.info("\(passed ? "PASS" : "FAIL") [\(category)] \(name): \(message)")
        }
        
        status = .finished(passed: passedCount, failed: failedCount)
        isRunning = false
    }
    
    /// Run tests for a single category
    func runCategory(_ category: String) async {
        guard !isRunning else { return }
        isRunning = true
        results = results.filter { $0.category != category }
        
        buildTestList()
        let categoryTests = allTests.filter { $0.1 == category }
        let total = categoryTests.count
        
        for (index, test) in categoryTests.enumerated() {
            let (name, cat, testFn) = test
            status = .running(current: name, progress: Double(index) / Double(total))
            
            let start = Date()
            let (passed, message) = await testFn()
            let duration = Date().timeIntervalSince(start)
            
            results.append(TestResult(
                name: name, category: cat,
                passed: passed, message: message, duration: duration
            ))
        }
        
        status = .finished(passed: passedCount, failed: failedCount)
        isRunning = false
    }
    
    // MARK: - Test Registry
    
    private func buildTestList() {
        allTests = []
        
        // Permissions
        allTests.append(("Screen Recording Permission", "Permissions", testScreenRecordingPermission))
        allTests.append(("Accessibility Permission", "Permissions", testAccessibilityPermission))
        allTests.append(("Local Network IP Available", "Permissions", testLocalNetworkIP))
        
        // Bonjour
        allTests.append(("Peer Service Advertising", "Bonjour", testPeerAdvertising))
        allTests.append(("Peer Service Discovery", "Bonjour", testPeerDiscovery))
        allTests.append(("LocalCast Bonjour Advertise+Browse", "Bonjour", testLocalCastBonjour))
        allTests.append(("TidalDrop Listener Active", "Bonjour", testTidalDropListener))
        
        // Network
        allTests.append(("UDP Port Bind", "Network", testUDPPortBind))
        allTests.append(("TCP Port Bind", "Network", testTCPPortBind))
        allTests.append(("Loopback TCP Roundtrip", "Network", testLoopbackTCPRoundtrip))
        allTests.append(("Loopback UDP Roundtrip", "Network", testLoopbackUDPRoundtrip))
        
        // Security
        allTests.append(("Session Key Generation", "Security", testSessionKeyGeneration))
        allTests.append(("HKDF Key Derivation", "Security", testHKDFKeyDerivation))
        allTests.append(("AES-GCM Encrypt/Decrypt", "Security", testAESGCMRoundtrip))
        allTests.append(("Tampered Ciphertext Rejected", "Security", testTamperedCiphertextRejected))
        allTests.append(("Wrong Password Rejected", "Security", testWrongPasswordRejected))
        
        // TidalDrop File Transfer
        allTests.append(("Loopback File Transfer (small)", "TidalDrop", testLoopbackSmallFileTransfer))
        allTests.append(("Loopback File Transfer (1MB)", "TidalDrop", testLoopbackLargeFileTransfer))
        allTests.append(("Drop Destination Folder Exists", "TidalDrop", testDropDestinationExists))
        
        // LocalCast
        allTests.append(("Streaming Tuning Interpolation", "LocalCast", testStreamingTuningInterpolation))
        allTests.append(("Quality Payload Encode/Decode", "LocalCast", testQualityPayloadCodable))
        allTests.append(("Packet Protocol Encode/Decode", "LocalCast", testPacketProtocol))
        allTests.append(("Host Session Start (loopback)", "LocalCast", testHostSessionLoopback))
    }
}
