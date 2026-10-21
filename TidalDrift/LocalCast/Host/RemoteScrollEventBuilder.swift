import CoreGraphics

/// Builds events without posting them, keeping fractional input between packets.
/// Callers serialize access and reset this state when the viewer releases input.
struct RemoteScrollEventBuilder {
    private var remainderX = 0.0
    private var remainderY = 0.0
    private var previousPrecise: Bool?

    mutating func makeEvent(
        deltaX: Double, deltaY: Double, precise: Bool, location: CGPoint?
    ) -> CGEvent? {
        guard deltaX.isFinite, deltaY.isFinite else { return nil }
        if previousPrecise != precise {
            remainderX = 0
            remainderY = 0
        }
        previousPrecise = precise
        // Bound untrusted input before converting to Int32. Preserve the small
        // remainder instead of discarding slow gestures one packet at a time.
        let x = min(max(deltaX, -10_000), 10_000) + remainderX
        let y = min(max(deltaY, -10_000), 10_000) + remainderY
        let dx = Int32(x.rounded(.towardZero))
        let dy = Int32(y.rounded(.towardZero))
        remainderX = x - Double(dx)
        remainderY = y - Double(dy)
        guard dx != 0 || dy != 0 else { return nil }
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
            wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0
        ) else { return nil }
        if let location { event.location = location }
        return event
    }
}
