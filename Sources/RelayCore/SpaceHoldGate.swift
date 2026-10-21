import Foundation

/// Tracks one physical Space press. Keyboard auto-repeat never starts a new hold.
public struct SpaceHoldGate {
    public static let duration: TimeInterval = 2.5
    private var pressedAt: TimeInterval?
    private var fired = false

    public init() {}

    /// Returns true only when a fresh, unmodified press needs a timer.
    public mutating func press(at time: TimeInterval, isRepeat: Bool, hasModifiers: Bool) -> Bool {
        if hasModifiers { cancel(); return false }
        guard !isRepeat, pressedAt == nil else { return false }
        pressedAt = time
        fired = false
        return true
    }

    public mutating func cancel() { pressedAt = nil; fired = false }

    /// A release ends only a hold that actually activated, exactly once.
    public mutating func release() -> Bool {
        let activated = fired
        cancel()
        return activated
    }

    /// Recheck physical key state so a missed release cannot activate the microphone.
    public mutating func activate(at time: TimeInterval, spaceIsDown: Bool, hasModifiers: Bool) -> Bool {
        guard spaceIsDown, !hasModifiers else { cancel(); return false }
        guard let pressedAt, !fired, time - pressedAt >= Self.duration else { return false }
        fired = true
        return true
    }
}
