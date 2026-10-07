import Foundation

/// Stable IDs distinguish player holes (UUID strings) from fixed bodies (e.g. "body-3").
public struct FlightHapticAttractor: Sendable {
    public let id: String
    public let position: Vec2
    public let mass: Double
    public let radius: Double
    public let isPlayerHole: Bool

    public init(id: String, position: Vec2, mass: Double, radius: Double, isPlayerHole: Bool = true) {
        self.id = id; self.position = position; self.mass = mass
        self.radius = radius; self.isPlayerHole = isPlayerHole
    }
}

public struct FlightHapticSample: Equatable, Sendable {
    public let intensity: Double
    public let sharpness: Double
    /// Start one short, shaped haptic envelope when true; never an unbroken buzz.
    public let shouldPulse: Bool
    public let dominantID: String?
    public static let silent = Self(intensity: 0, sharpness: 0, shouldPulse: false, dominantID: nil)
}

/// Pure mapping, without timers, UIKit, Core Haptics, or changes to the flight.
/// Inputs use logical-world units. elapsed is WALL time, including at 4x playback.
public struct FlightHapticMapper: Sendable {
    public static let maximumIntensity = 0.65
    public static let minimumPulseInterval = 0.25
    public static let maximumPlayerHoles = 32
    public static let maximumSources = 48

    private var intensity = 0.0
    private var sharpness = 0.0
    private var sincePulse = 0.0
    private var dominantID: String?
    private var challengerID: String?
    private var challengerAge = 0.0

    public init() {}
    public mutating func reset() { self = Self() }

    /// Pass the current simulation acceleration (Physics.pullAt), never scaled velocity.
    /// At most 32 player holes and 48 total sources are inspected. Supply stable ordering.
    /// Reset on inactive/paused/finished, interruption, or teleport before the next sample.
    public mutating func update(active: Bool, position: Vec2, velocity: Vec2,
                                acceleration: Vec2, attractors: [FlightHapticAttractor],
                                elapsed: Double) -> FlightHapticSample {
        guard active, elapsed.isFinite, elapsed > 0, elapsed <= 0.25,
              finite(position), finite(velocity), finite(acceleration) else {
            reset(); return .silent
        }

        struct Source { let id: String; let score: Double; let proximity: Double }
        var best: Source?
        var current: Source?
        var playerCount = 0
        for source in attractors.prefix(Self.maximumSources) {
            if source.isPlayerHole {
                guard playerCount < Self.maximumPlayerHoles else { continue }
                playerCount += 1
            }
            guard finite(source.position), source.mass.isFinite, source.mass != 0,
                  source.radius.isFinite, source.radius >= 0 else { continue }
            let distance = hypot(source.position.x - position.x, source.position.y - position.y)
            guard distance.isFinite else { continue }
            let clearance = max(0, distance - source.radius)
            let reach = max(distance, source.radius)
            let candidate = Source(id: source.id,
                                   score: min(abs(source.mass), 1_000) / (reach * reach + 36),
                                   proximity: 1 / (1 + pow(clearance / 140, 2)))
            if best == nil || candidate.score > best!.score { best = candidate }
            if candidate.id == dominantID { current = candidate }
        }

        // Require a persistent 20% lead; equal or noisy neighbors cannot alternate each frame.
        if let best, let current, best.id != current.id,
           best.score > current.score * 1.2 + 1e-12 {
            if challengerID != best.id { challengerID = best.id; challengerAge = 0 }
            challengerAge += elapsed
            if challengerAge + 1e-12 >= 0.15 {
                dominantID = best.id; challengerID = nil; challengerAge = 0
            }
        } else {
            challengerID = nil; challengerAge = 0
            if current == nil { dominantID = best?.id }
        }
        let proximity = dominantID == best?.id ? (best?.proximity ?? 0) : (current?.proximity ?? 0)

        // Bounds protect the mapping from overflow without modifying simulation values.
        let vx = bounded(velocity.x), vy = bounded(velocity.y)
        let ax = bounded(acceleration.x), ay = bounded(acceleration.y)
        let speed = hypot(vx, vy)
        let ux = vx / max(speed, 1), uy = vy / max(speed, 1)
        let speedCue = unit(speed / 600)
        let accelerationCue = unit(hypot(ax, ay) / 300)
        let speedChangeCue = unit(abs(ux * ax + uy * ay) / 250)
        let turnCue = unit(abs(ux * ay - uy * ax) / max(speed, 40) / 2)
        let targetIntensity = min(Self.maximumIntensity,
                                  0.02 * speedCue + 0.38 * proximity + 0.14 * accelerationCue
                                  + 0.08 * turnCue + 0.05 * speedChangeCue)
        let targetSharpness = min(0.85, 0.15 + 0.25 * speedCue + 0.30 * turnCue + 0.15 * accelerationCue)
        // Exponential smoothing gives the same response at 30, 60, and 120 Hz.
        intensity += (targetIntensity - intensity) * -expm1(-elapsed / 0.18)
        sharpness += (targetSharpness - sharpness) * -expm1(-elapsed / 0.12)
        sincePulse = min(2, sincePulse + elapsed)
        let interval = max(Self.minimumPulseInterval, 0.8 - 0.5 * intensity / Self.maximumIntensity)
        let pulse = intensity >= 0.04 && sincePulse + 1e-12 >= interval
        if pulse { sincePulse = 0 }
        return FlightHapticSample(intensity: intensity, sharpness: sharpness,
                                  shouldPulse: pulse, dominantID: dominantID)
    }

    private func finite(_ value: Vec2) -> Bool { value.x.isFinite && value.y.isFinite }
    private func bounded(_ value: Double) -> Double { min(1_000_000, max(-1_000_000, value)) }
    private func unit(_ value: Double) -> Double { min(1, max(0, value)) }
}
