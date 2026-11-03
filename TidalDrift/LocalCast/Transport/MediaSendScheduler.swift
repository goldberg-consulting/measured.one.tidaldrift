import Foundation
import Network

/// One FIFO and byte budget per connection, rather than independent timers per
/// frame. Control packets bypass this queue. The eight-MB bound prevents an
/// overloaded sender retaining an unlimited video backlog.
final class MediaSendScheduler {
    enum FrameKind {
        case dependent // Video deltas and region updates need an intact picture.
        case keyFrame
    }

    private enum Recovery {
        case normal, draining, waitingForKeyFrame
    }

    private final class Stream {
        let connection: NWConnection
        var budget: MediaPacingBudget
        var frames: [[Data]] = []
        var fragmentIndex = 0
        var queuedBytes = 0
        var recovery = Recovery.normal
        let generation = UUID()
        init(connection: NWConnection, settings: NetworkTuning) {
            self.connection = connection
            budget = MediaPacingBudget(settings: settings)
        }
    }

    private let queue = DispatchQueue(label: "com.tidaldrift.localcast.shared-pacing", qos: .userInteractive)
    private var streams: [ObjectIdentifier: Stream] = [:]
    private let settings: NetworkTuning
    private let send: ([Data], NWConnection) -> Void
    private let dropped: () -> Void
    private let recover: () -> Void
    private var stopped = false
    static let maximumQueuedBytes = 8_000_000

    init(settings: NetworkTuning, send: @escaping ([Data], NWConnection) -> Void,
         dropped: @escaping () -> Void, recover: @escaping () -> Void) {
        self.settings = settings.validated
        self.send = send
        self.dropped = dropped
        self.recover = recover
    }

    func enqueue(_ fragments: [Data], on connection: NWConnection, kind: FrameKind = .dependent) {
        queue.async { [self] in
            guard !stopped, !fragments.isEmpty else { return }
            streams = streams.filter { $0.value.connection.state == .ready }
            let key = ObjectIdentifier(connection)
            let stream = streams[key] ?? Stream(connection: connection, settings: settings)
            streams[key] = stream
            if stream.recovery == .draining || (stream.recovery == .waitingForKeyFrame && kind != .keyFrame) {
                dropped()
                return
            }
            let bytes = fragments.reduce(0) { $0 + $1.count }
            // Allow one large frame to finish even if it exceeds the delay target;
            // additional frames must fit the time budget and the hard memory cap.
            let timeBudgetBytes = Int(stream.budget.rateMbps * 125 * Double(settings.queueMilliseconds))
            let limit = min(Self.maximumQueuedBytes, max(bytes, timeBudgetBytes))
            guard stream.queuedBytes + bytes <= limit else {
                dropped()
                stream.recovery = .draining
                if stream.frames.isEmpty { requestKeyFrame(for: stream) }
                return
            }
            let idle = stream.frames.isEmpty
            stream.frames.append(fragments)
            stream.queuedBytes += bytes
            stream.recovery = .normal
            if idle { drain(key, generation: stream.generation) }
        }
    }

    private func requestKeyFrame(for stream: Stream) {
        // The encoder produces the repair asynchronously. A delta already in
        // flight must not consume the empty queue before the repair arrives.
        stream.recovery = .waitingForKeyFrame
        recover()
    }

    func reset() { queue.async { [self] in streams.removeAll() } }

    func feedback(incompleteFrames: Int) {
        queue.async { [self] in
            for stream in streams.values { stream.budget.feedback(incompleteFrames: incompleteFrames) }
        }
    }

    /// Synchronously invalidate timers before transport cancellation. Never called
    /// by the scheduler queue; UDPTransport owns lifecycle from its caller queue.
    func stop() {
        queue.sync { stopped = true; streams.removeAll() }
    }

    private func drain(_ key: ObjectIdentifier, generation: UUID) {
        guard !stopped, let stream = streams[key], stream.generation == generation else { return }
        guard stream.connection.state == .ready else { streams.removeValue(forKey: key); return }
        let now = ProcessInfo.processInfo.systemUptime
        let delay = stream.budget.delay(at: now)
        if delay > 0 {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.drain(key, generation: generation) }
            return
        }
        guard let frame = stream.frames.first else { return }
        var batch: [Data] = []
        var bytes = 0
        while stream.fragmentIndex < frame.count {
            let fragment = frame[stream.fragmentIndex]
            if !batch.isEmpty, bytes + fragment.count > stream.budget.burstBytes { break }
            batch.append(fragment)
            bytes += fragment.count
            stream.fragmentIndex += 1
        }
        send(batch, stream.connection)
        stream.queuedBytes -= bytes
        stream.budget.sent(bytes: bytes, at: now)
        if stream.fragmentIndex == frame.count {
            stream.frames.removeFirst()
            stream.fragmentIndex = 0
        }
        if !stream.frames.isEmpty {
            queue.asyncAfter(deadline: .now() + stream.budget.delay(at: ProcessInfo.processInfo.systemUptime)) { [weak self] in
                self?.drain(key, generation: generation)
            }
        } else if stream.recovery == .draining {
            requestKeyFrame(for: stream)
        }
    }
}
