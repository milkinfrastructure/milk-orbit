import Foundation

/// Observations of completed Physics.step transitions, never collision predictions.
/// Direction is ship travel direction in world coordinates, not spatial haptic output.
public struct FlightEvent: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case portalEnter, portalExit, holeCapture, planetImpact, asteroidImpact, repulsorImpact
        case beacon, docked, lost, stranded
        public var isTerminal: Bool {
            switch self {
            case .portalEnter, .portalExit, .beacon: false
            default: true
            }
        }
    }
    public let sequence: UInt64
    public let kind: Kind
    public let simulationTime: Double
    public let position: Vec2
    public let direction: Vec2

    public init(sequence: UInt64, kind: Kind, simulationTime: Double, position: Vec2, direction: Vec2) {
        self.sequence = sequence; self.kind = kind; self.simulationTime = simulationTime
        self.position = position; self.direction = direction
    }
}

/// A finite one-shot recipe. Native code caches one player per kind.
public struct FlightHapticCue: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case portalTransit, holeCapture, planetImpact, asteroidImpact, repulsorImpact
        case beacon, docked, lost, stranded
    }
    public let kind: Kind
    public let delay: Double
    public init(kind: Kind, delay: Double = 0) { self.kind = kind; self.delay = delay }
}

/// Dedupes replayed render batches and prevents fast portal chains becoming chatter.
/// Terminal cues are never rate-limited. Wall time keeps the cadence fixed at any playback speed.
public struct FlightHapticEventMapper: Sendable {
    public static let minimumPortalInterval = 0.32
    public static let minimumBeaconInterval = 0.18
    private var lastSequence: UInt64 = 0
    private var lastPortalTime = -Double.infinity
    private var lastBeaconTime = -Double.infinity
    public init() {}

    /// Does not rewind the dedupe cursor: interruption must not replay old events.
    public mutating func resetCadence() {
        lastPortalTime = -.infinity; lastBeaconTime = -.infinity
    }

    public mutating func consume(_ events: [FlightEvent], wallTime: Double,
                                 enabled: Bool = true) -> [FlightHapticCue] {
        var portalEntered = false, portalCompleted = false, beacon = false
        var terminal: FlightHapticCue.Kind?
        for event in events.prefix(256) where event.sequence > lastSequence {
            lastSequence = event.sequence
            switch event.kind {
            case .portalEnter: portalEntered = true
            case .portalExit:
                if portalEntered { portalCompleted = true; portalEntered = false }
            case .beacon: beacon = true
            case .holeCapture: terminal = .holeCapture
            case .planetImpact: terminal = .planetImpact
            case .asteroidImpact: terminal = .asteroidImpact
            case .repulsorImpact: terminal = .repulsorImpact
            case .docked: terminal = .docked
            case .lost: terminal = .lost
            case .stranded: terminal = .stranded
            }
        }
        guard enabled, wallTime.isFinite else { return [] }
        var cues: [FlightHapticCue] = []
        if portalCompleted && wallTime - lastPortalTime >= Self.minimumPortalInterval {
            cues.append(.init(kind: .portalTransit)); lastPortalTime = wallTime
        }
        if let terminal {
            // Physics teleports instantly. Only tactile playback expands the ordered
            // pull/pop before the terminal event, by a bounded 0.21 seconds.
            cues.append(.init(kind: terminal, delay: cues.isEmpty ? 0 : 0.21))
        } else if cues.isEmpty && beacon && wallTime - lastPortalTime >= Self.minimumPortalInterval
                    && wallTime - lastBeaconTime >= Self.minimumBeaconInterval {
            cues.append(.init(kind: .beacon)); lastBeaconTime = wallTime
        }
        return cues
    }
}

/// Platform-independent recipes make ordering and intensity bounds testable in core tests.
/// A phone's single actuator cannot communicate an actual left/right spatial direction.
public struct FlightHapticRecipe: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public let time: Double
        public let intensity: Double
        public let sharpness: Double
        public init(_ time: Double, _ intensity: Double, _ sharpness: Double) {
            self.time = time; self.intensity = intensity; self.sharpness = sharpness
        }
    }
    public let envelope: [Point]
    public let transients: [Point]
    public var duration: Double { max(envelope.last?.time ?? 0, (transients.last?.time ?? -0.02) + 0.02) }

    public static func recipe(for kind: FlightHapticCue.Kind) -> Self {
        switch kind {
        case .portalTransit:
            // Pressure builds, narrows, disappears; then a separate crisp exit pop.
            Self(envelope: [.init(0, 0.08, 0.45), .init(0.07, 0.35, 0.25), .init(0.13, 0.55, 0.08), .init(0.15, 0, 0.08)],
                 transients: [.init(0.18, 0.64, 0.9)])
        case .holeCapture:
            Self(envelope: [.init(0, 0.12, 0.35), .init(0.09, 0.65, 0.12), .init(0.18, 0.3, 0.02), .init(0.25, 0, 0)], transients: [])
        case .planetImpact:
            Self(envelope: [], transients: [.init(0, 0.72, 0.95), .init(0.045, 0.2, 0.65)])
        case .asteroidImpact:
            Self(envelope: [], transients: [.init(0, 0.58, 0.85), .init(0.025, 0.16, 0.8)])
        case .repulsorImpact:
            Self(envelope: [], transients: [.init(0, 0.65, 0.9), .init(0.06, 0.16, 0.45)])
        case .beacon:
            Self(envelope: [], transients: [.init(0, 0.24, 0.55)])
        case .docked:
            Self(envelope: [], transients: [.init(0, 0.32, 0.5), .init(0.11, 0.52, 0.7)])
        case .lost, .stranded:
            Self(envelope: [], transients: [.init(0, 0.18, 0.1)])
        }
    }
}
