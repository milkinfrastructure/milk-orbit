import Foundation

public enum StrengthDirection: Double, Sendable {
    case decrease = -0.5
    case increase = 0.5
}

/// Caller owns one UI timer. Values come from a monotonic clock, never Date.
/// A late callback emits one step; missed repeats are discarded, never caught up.
public struct StrengthRepeat: Sendable {
    public static let delay = 0.35
    public static let interval = 0.1
    private var holeID: UUID?
    private var direction = StrengthDirection.increase
    private var nextTime = 0.0
    private var lastTime = 0.0
    public var isActive: Bool { holeID != nil }

    public init() {}

    public mutating func begin(holeID: UUID, direction: StrengthDirection, at time: Double) -> Double {
        guard !isActive else { return 0 } // Extra touch-down cannot add another immediate step.
        guard Self.valid(time) else { cancel(); return 0 }
        self.holeID = holeID
        self.direction = direction
        lastTime = time
        nextTime = time + Self.delay
        return direction.rawValue
    }

    public mutating func advance(at time: Double, selectedHoleID: UUID?, editable: Bool) -> Double {
        guard isActive else { return 0 }
        guard editable, selectedHoleID == holeID, Self.valid(time), time >= lastTime else {
            cancel(); return 0
        }
        lastTime = time
        guard time + 1e-9 >= nextTime else { return 0 }
        nextTime = time + Self.interval
        return direction.rawValue
    }

    /// Invoke after applying an emitted step through the core. A clamp stops idle work.
    public mutating func didApply(before: Double, after: Double) {
        if !before.isFinite || !after.isFinite || before == after { cancel() }
    }

    /// Release, drag-exit, touch-cancel, removal, reset, rotation, background, teardown.
    public mutating func cancel() {
        holeID = nil
        nextTime = 0
        lastTime = 0
    }

    private static func valid(_ time: Double) -> Bool {
        time.isFinite && time >= 0 && time + interval > time
    }
}

/// Observe committed half-step values, not raw finger positions. No quarter-step
/// hysteresis here: it would suppress a real half-step change under the new rule.
public struct StrengthChangeFeedback: Sendable {
    private var lastTick: Double?
    public init() {}

    public mutating func reset(to strength: Double? = nil) {
        lastTick = strength.flatMap(Self.tick)
    }

    /// One click for this actual update, never a queued burst for skipped values.
    public mutating func changed(to strength: Double) -> Bool {
        guard let tick = Self.tick(strength) else { reset(); return false }
        defer { lastTick = tick }
        guard let previous = lastTick else { return false }
        return tick != previous
    }

    private static func tick(_ strength: Double) -> Double? {
        let scaled = strength * 2
        guard strength >= 0, scaled.isFinite, scaled + 1 > scaled,
              abs(scaled - scaled.rounded()) < 1e-8 else { return nil }
        return scaled.rounded()
    }
}
