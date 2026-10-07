import Foundation

public enum GamePhase: String, Codable, Equatable, Sendable {
    case setup
    case flying
    case finished
}

/// The game and touch transaction state, independent of UIKit and the display rate.
/// Call from the owning UI thread; no timers or background tasks are needed.
public final class GameSession {
    public static let massPerScreenPoint = 0.35
    public static let fastForwardMultiplier = 4.0

    public private(set) var level: Level
    public private(set) var holes: [Hole] = []
    public private(set) var selectedID: UUID?
    public private(set) var phase: GamePhase = .setup
    public private(set) var flight: Flight?
    /// Nil separates the two sides of a wormhole jump.
    public private(set) var preview: [Vec2?] = []
    public private(set) var trail: [Vec2?] = []
    public private(set) var ghost: [Vec2?] = []
    /// Last completed run, distinct from the prediction and short current flight trail.
    /// Retained through edits/Reset; cleared only by an accepted new launch.
    /// At most 4096 samples per sector, including nil portal separators.
    public private(set) var lastCompletedTrail: [Vec2?] = []
    // Other sectors only: the active sector remains in lastCompletedTrail.
    private var cachedTrailsByLevel: [String: [Vec2?]] = [:]
    public private(set) var launches = 0
    public private(set) var assisted = false
    public private(set) var isFastForwarding = false
    public private(set) var lastFeedback: String?
    public var holeLimit: Int { Physics.holeLimit(for: level) }
    public var remainingHoleSlots: Int { max(0, holeLimit - holes.count) }
    public var remainingPlacements: Int { min(remainingHoleSlots, Int(availableMatter / Physics.minMass)) }

    public var availableMatter: Double {
        max(0, level.matter - holes.reduce(0) { $0 + $1.mass })
    }
    public var canUndo: Bool { phase == .setup && gesture == nil && !history.isEmpty }
    public var isInteracting: Bool { gesture != nil }
    public var activeHoleID: UUID? { gesture?.holeID }
    public var selectedHole: Hole? { holes.first { $0.id == selectedID } }

    fileprivate struct Snapshot: Codable, Sendable {
        var holes: [Hole]
        var selectedID: UUID?
        var ghost: [Vec2?]
        var assisted: Bool
    }

    private struct Gesture {
        var holeID: UUID
        var originY: Double
        var initialMass: Double
        var capacity: Double
        var before: Snapshot
    }

    private var gesture: Gesture?
    private var history: [Snapshot] = []
    private var accumulatedTime = 0.0
    private var flightSteps = 0
    // Events are transient presentation observations; checkpoints never replay them.
    private var flightEvents: [FlightEvent] = []
    private var eventSequence: UInt64 = 0

    public func drainFlightEvents() -> [FlightEvent] {
        let events = flightEvents
        flightEvents.removeAll(keepingCapacity: true)
        return events
    }
    public func discardFlightEvents() { flightEvents.removeAll(keepingCapacity: true) }

    public init(level: Level) {
        self.level = level
        refreshPreview()
    }

    public func hole(at point: Vec2, hitRadius: Double) -> Hole? {
        guard point.x.isFinite, point.y.isFinite, hitRadius.isFinite, hitRadius >= 0,
              point.x >= 0, point.x <= Physics.worldWidth, point.y >= 0, point.y <= Physics.worldHeight else { return nil }
        return holes.filter { hole in
            let reach = max(Physics.horizonRadius(mass: hole.mass) + 6, hitRadius)
            return distanceSquared(hole.position, point) <= reach * reach
        }.min { distanceSquared($0.position, point) < distanceSquared($1.position, point) }
    }

    public func clearSelection() {
        guard gesture == nil else { return }
        selectedID = nil; lastFeedback = nil
    }

    /// Dismissal is a complete, consumed tap, never a placement transaction.
    public func dismissIfEmpty(hitHole: Hole?, additionalOverlay: Bool = false) -> Bool {
        guard gesture == nil, selectedID != nil || additionalOverlay,
              hitHole == nil else { return false }
        clearSelection(); return true
    }

    /// Touch-down places a minimum-size hole immediately, or selects an existing one.
    /// `screenY` stays in UIKit points, so sizing feels the same at every board scale.
    @discardableResult
    public func begin(at point: Vec2, screenY: Double, hitRadius: Double) -> Bool {
        guard phase == .setup, gesture == nil,
              point.x.isFinite, point.y.isFinite, screenY.isFinite,
              point.x >= 0, point.x <= Physics.worldWidth,
              point.y >= 0, point.y <= Physics.worldHeight,
              hitRadius.isFinite, hitRadius >= 0 else { return false }

        lastFeedback = nil
        let before = snapshot()
        let hit = hole(at: point, hitRadius: hitRadius)

        if let hole = hit {
            selectedID = hole.id
            let others = holes.filter { $0.id != hole.id }
            let capacity = Physics.capacityAt(level: level, holes: others, x: hole.x, y: hole.y)
            gesture = Gesture(holeID: hole.id, originY: screenY, initialMass: hole.mass,
                              capacity: capacity, before: before)
            return true
        }

        selectedID = nil
        let capacity = Physics.capacityAt(level: level, holes: holes, x: point.x, y: point.y)
        guard capacity >= Physics.minMass - 1e-9 else {
            lastFeedback = Physics.placementReason(level: level, holes: holes, at: point)
            return false
        }
        let hole = Hole(x: point.x, y: point.y, mass: Physics.minMass)
        holes.append(hole)
        selectedID = hole.id
        gesture = Gesture(holeID: hole.id, originY: screenY, initialMass: hole.mass,
                          capacity: capacity, before: before)
        ghost = []
        refreshPreview()
        return true
    }

    /// Up increases mass; down decreases it. The center never follows the finger.
    /// Holding still has no effect, and no pressure-capable screen is required.
    public func drag(screenY: Double) {
        guard screenY.isFinite, phase == .setup, let gesture,
              let index = holes.firstIndex(where: { $0.id == gesture.holeID }) else { return }
        let requested = gesture.initialMass + (gesture.originY - screenY) * Self.massPerScreenPoint
        let maximum = floor(gesture.capacity * 2 + 1e-9) / 2
        let mass = min(maximum, max(Physics.minMass, (requested * 2).rounded() / 2))
        guard mass >= Physics.minMass - 1e-9, holes[index].mass != mass else { return }
        holes[index].mass = mass
        ghost = []
        refreshPreview()
    }

    /// Begin resizing where directional intent locks, avoiding a jump across touch slop.
    public func reanchorStrength(screenY: Double) {
        guard screenY.isFinite, var current = gesture,
              let hole = holes.first(where: { $0.id == current.holeID }) else { return }
        current.originY = screenY; current.initialMass = hole.mass
        gesture = current
    }

    public func dragPrecisely(screenY: Double) {
        guard screenY.isFinite, let gesture else { return }
        setStrength(gesture.initialMass * exp((gesture.originY - screenY) / 50))
    }

    /// Adjust the active edit transaction; end commits and cancel restores its starting state.
    public func setStrength(_ requested: Double) {
        guard !requested.isNaN, phase == .setup, let gesture,
              let index = holes.firstIndex(where: { $0.id == gesture.holeID }) else { return }
        let maximum = floor(gesture.capacity * 2 + 1e-9) / 2
        let mass = min(maximum, max(Physics.minMass, (requested * 2).rounded() / 2))
        lastFeedback = requested > gesture.capacity + 1e-9
            ? "Strength limited by the remaining budget or nearby objects." : nil
        guard holes[index].mass != mass else { return }
        holes[index].mass = mass; ghost = []; refreshPreview()
    }

    public func adjustSelected(by delta: Double) {
        guard delta.isFinite, let hole = selectedHole,
              begin(at: hole.position, screenY: 0, hitRadius: 0) else { return }
        setStrength(hole.mass + delta); end()
    }

    /// Snap movement to a 40-unit grid without spending matter. Legal edge stops remain reachable.
    /// Illegal positions
    /// leave the hole at its last valid location; the whole drag remains one undo.
    public func move(to point: Vec2) {
        guard phase == .setup, point.x.isFinite, point.y.isFinite,
              let gesture, let index = holes.firstIndex(where: { $0.id == gesture.holeID }) else { return }
        let hole = holes[index]
        let edge = Physics.horizonRadius(mass: hole.mass) + Physics.clearance
        let point = Vec2(x: min(Physics.worldWidth - edge, max(edge, (point.x / 40).rounded() * 40)),
                         y: min(Physics.worldHeight - edge, max(edge, (point.y / 40).rounded() * 40)))
        let capacity = Physics.capacityAt(level: level, holes: holes.filter { $0.id != hole.id },
                                          x: point.x, y: point.y)
        guard capacity + 1e-9 >= hole.mass else {
            lastFeedback = "Not enough clearance to move this hole here."
            return
        }
        lastFeedback = nil
        guard point != hole.position else { return }
        holes[index].x = point.x
        holes[index].y = point.y
        ghost = []
        refreshPreview()
    }

    /// Speed changes only wall-clock playback; the integrator and velocities stay unchanged.
    public func setFastForwarding(_ held: Bool) {
        isFastForwarding = held && phase == .flying
    }

    /// Commit the entire continuous touch as one undoable change.
    public func end() {
        guard let gesture else { return }
        self.gesture = nil
        if holes != gesture.before.holes {
            remember(gesture.before)
        } else {
            // Returning a resize to its starting value also restores the previous trail.
            ghost = gesture.before.ghost
            assisted = gesture.before.assisted
        }
    }

    /// System interruptions and a cancelled recognizer refund all matter from that touch.
    public func cancel() {
        guard let gesture else { return }
        self.gesture = nil
        restore(gesture.before)
    }

    public func deleteSelected() {
        guard phase == .setup, gesture == nil, let selectedID,
              let index = holes.firstIndex(where: { $0.id == selectedID }) else { return }
        remember(snapshot())
        holes.remove(at: index)
        lastFeedback = nil
        // A supplied layout remains assisted through edits; an empty board is a fresh start.
        if holes.isEmpty { assisted = false }
        self.selectedID = nil
        ghost = []
        refreshPreview()
    }

    public func undo() {
        guard canUndo, let last = history.popLast() else { return }
        restore(last)
    }

    /// Reset is itself one undoable action.
    public func reset() {
        discardFlightEvents()
        guard phase == .setup, gesture == nil, !holes.isEmpty else { return }
        remember(snapshot())
        holes = []
        lastFeedback = nil
        assisted = false
        selectedID = nil
        ghost = []
        refreshPreview()
    }

    /// A new campaign discards reference routes as well as the current board.
    /// Ordinary sector navigation and Reset deliberately keep those routes.
    public func restartCampaign(at level: Level) {
        lastCompletedTrail = []
        cachedTrailsByLevel.removeAll()
        load(level: level)
    }

    /// Drop unmappable catalog overlays before they displace a valid cached route.
    /// The app archives the original checkpoint when this reports a change.
    @discardableResult
    public func pruneCachedTrails(keeping levelNames: Set<String>) -> Bool {
        let previousCount = cachedTrailsByLevel.count
        cachedTrailsByLevel = cachedTrailsByLevel.filter { levelNames.contains($0.key) }
        return cachedTrailsByLevel.count != previousCount
    }

    public func load(level: Level) {
        discardFlightEvents()
        if lastCompletedTrail.isEmpty { cachedTrailsByLevel.removeValue(forKey: self.level.name) }
        else { cachedTrailsByLevel[self.level.name] = lastCompletedTrail }
        lastCompletedTrail = cachedTrailsByLevel.removeValue(forKey: level.name) ?? []
        // All 20 catalog sectors fit. Also bound sessions given arbitrary custom levels.
        for name in cachedTrailsByLevel.keys.sorted().prefix(max(0, cachedTrailsByLevel.count - 19)) {
            cachedTrailsByLevel.removeValue(forKey: name)
        }
        self.level = level
        holes = []
        selectedID = nil
        gesture = nil
        history = []
        phase = .setup
        flight = nil
        trail = []
        ghost = []
        launches = 0
        assisted = false
        accumulatedTime = 0
        flightSteps = 0
        isFastForwarding = false
        lastFeedback = nil
        refreshPreview()
    }

    private func remember(_ snapshot: Snapshot) {
        history.append(snapshot)
        if history.count > 64 { history.removeFirst(history.count - 64) }
    }

    @discardableResult
    public func launch() -> Bool {
        guard phase == .setup else { return false }
        end()
        guard !Physics.becalmed(level: level, holes: holes) else { return false }
        lastCompletedTrail = []
        let flight = Physics.launch(level: level)
        discardFlightEvents()
        self.flight = flight
        trail = [flight.position]
        selectedID = nil
        phase = .flying
        launches += 1
        accumulatedTime = 0
        flightSteps = 0
        isFastForwarding = false
        return true
    }

    /// Abort or return from a finished flight without losing the player's layout.
    public func retry() {
        discardFlightEvents()
        guard phase != .setup else { return }
        ghost = trail
        trail = []
        phase = .setup
        flight = nil
        selectedID = nil
        accumulatedTime = 0
        flightSteps = 0
        isFastForwarding = false
        refreshPreview()
    }

    /// Feed CADisplayLink elapsed time here. The simulation always uses 240 Hz steps.
    /// Clamp long frame gaps to 0.1 seconds instead of simulating a suspension.
    public func tick(elapsed: Double) {
        guard phase == .flying, elapsed.isFinite, elapsed > 0, var flight else { return }
        discardFlightEvents() // At most one bounded frame batch; the UI drains after tick.
        accumulatedTime += min(elapsed, 0.1) * (isFastForwarding ? Self.fastForwardMultiplier : 1)
        while accumulatedTime + 1e-12 >= Physics.stepDuration && flight.status == .flying {
            Physics.step(level: level, holes: holes, flight: &flight)
            recordFlightEvents(flight)
            accumulatedTime = max(0, accumulatedTime - Physics.stepDuration)
            flightSteps += 1
            if flight.jumped != nil { trail.append(nil) }
            if flightSteps.isMultiple(of: 3) || flight.status != .flying {
                trail.append(flight.position)
            }
        }
        self.flight = flight
        if flight.status != .flying {
            lastCompletedTrail = Array(trail.prefix(4096))
            phase = .finished
            isFastForwarding = false
            accumulatedTime = 0
        }
    }

    private func recordFlightEvents(_ flight: Flight) {
        guard flight.jumped != nil || flight.reached != nil || flight.status != .flying else { return }
        let speed = hypot(flight.vx, flight.vy)
        let direction = speed.isFinite && speed > 1e-9 ? flight.velocity / speed : .zero
        func emit(_ kind: FlightEvent.Kind, at point: Vec2) {
            // One clamped frame has at most 96 steps × 2 events at the current 4× cap.
            // Keep a hard bound if playback limits change; preserve latest terminal data.
            if flightEvents.count == 256 { flightEvents.removeFirst() }
            eventSequence &+= 1
            flightEvents.append(.init(sequence: eventSequence, kind: kind,
                                      simulationTime: flight.time, position: point, direction: direction))
        }
        if let jump = flight.jumped {
            let time = max(0, flight.time - Physics.stepDuration)
            emit(.portalEnter, at: Physics.bodyAt(body: jump.from, time: time))
            emit(.portalExit, at: Physics.bodyAt(body: jump.to, time: time))
        }
        if let beacon = flight.reached { emit(.beacon, at: beacon.position) }
        switch flight.status {
        case .flying: break
        case .imploded: emit(.holeCapture, at: flight.position)
        case .crashed:
            if case .body(let body) = flight.cause {
                switch body.type {
                case .planet: emit(.planetImpact, at: flight.position)
                case .repulsor: emit(.repulsorImpact, at: flight.position)
                case .asteroid: emit(.asteroidImpact, at: flight.position)
                default: break // Physics cannot produce .crashed for holes/portals.
                }
            }
        case .won: emit(.docked, at: flight.position)
        case .lost: emit(.lost, at: flight.position)
        case .stranded: emit(.stranded, at: flight.position)
        }
    }

    /// Reveal the sector's supplied solution as an undoable, assisted edit.
    public func showSolution() {
        lastFeedback = nil
        guard phase == .setup, gesture == nil else { return }
        remember(snapshot())
        holes = level.answer
        assisted = true
        selectedID = nil
        ghost = []
        refreshPreview()
    }

    private func snapshot() -> Snapshot {
        Snapshot(holes: holes, selectedID: selectedID, ghost: ghost, assisted: assisted)
    }

    private func restore(_ snapshot: Snapshot) {
        lastFeedback = nil
        holes = snapshot.holes
        selectedID = snapshot.selectedID
        ghost = snapshot.ghost
        assisted = snapshot.assisted
        refreshPreview()
    }

    private func refreshPreview() {
        var flight = Physics.launch(level: level)
        preview = [flight.position]
        let steps = Int((4 / Physics.stepDuration).rounded())
        for index in 1...steps {
            guard flight.status == .flying else { break }
            Physics.step(level: level, holes: holes, flight: &flight)
            if flight.jumped != nil { preview.append(nil) }
            if index.isMultiple(of: 3) || flight.status != .flying {
                preview.append(flight.position)
            }
        }
    }

    private func distanceSquared(_ a: Vec2, _ b: Vec2) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }
}

extension GameSession {
    /// A versioned value, independent of views, timers, and device orientation.
    public struct Checkpoint: Codable, Sendable {
        public let version: Int
        public var levelName: String { level.name }
        /// Titles and teaching copy may change; every gameplay rule must still match.
        public func matches(_ candidate: Level) -> Bool {
            var saved = GameSession.checkpointIdentity(level)
            saved.name = candidate.name
            return saved == GameSession.checkpointIdentity(candidate)
        }
        fileprivate let level: Level
        fileprivate let holes: [Hole]
        fileprivate let selectedID: UUID?
        fileprivate let phase: GamePhase
        fileprivate let flight: Flight?
        fileprivate let trail: [Vec2?]
        fileprivate let ghost: [Vec2?]
        fileprivate let lastCompletedTrail: [Vec2?]
        // Optional so existing version-1 checkpoints continue decoding.
        fileprivate let cachedTrailsByLevel: [String: [Vec2?]]?
        fileprivate let launches: Int
        fileprivate let assisted: Bool
        fileprivate let history: [Snapshot]
        fileprivate let accumulatedTime: Double
        fileprivate let flightSteps: Int
    }

    public enum CheckpointError: Error, Equatable {
        case unsupportedVersion, levelMismatch, invalidState
    }

    /// Captures the last legal drag position as one undoable edit in the saved value.
    /// Does not mutate the running session. Held speed/touch/timer state is never saved.
    public func checkpoint() -> Checkpoint {
        var savedHistory = history
        var savedGhost = ghost
        var savedAssisted = assisted
        if let gesture {
            if holes != gesture.before.holes {
                savedHistory.append(gesture.before)
                savedHistory = Array(savedHistory.suffix(64))
            } else {
                savedGhost = gesture.before.ghost
                savedAssisted = gesture.before.assisted
            }
        }
        return Checkpoint(version: 1, level: Self.checkpointIdentity(level), holes: holes,
                          selectedID: selectedID, phase: phase, flight: flight, trail: trail,
                          ghost: savedGhost, lastCompletedTrail: lastCompletedTrail,
                          cachedTrailsByLevel: cachedTrailsByLevel,
                          launches: launches, assisted: savedAssisted, history: savedHistory,
                          accumulatedTime: accumulatedTime, flightSteps: flightSteps)
    }

    /// Supply the authoritative catalog level; never use decoded level rules to play.
    public convenience init(restoring checkpoint: Checkpoint, level: Level) throws {
        guard checkpoint.version == 1 else { throw CheckpointError.unsupportedVersion }
        guard checkpoint.matches(level) else { throw CheckpointError.levelMismatch }
        guard Self.valid(checkpoint, for: level) else { throw CheckpointError.invalidState }
        self.init(level: level)
        holes = checkpoint.holes
        selectedID = checkpoint.selectedID
        phase = checkpoint.phase
        flight = checkpoint.flight
        trail = checkpoint.trail
        ghost = checkpoint.ghost
        // Legacy v1 could carry the preceding trail into an already-started flight.
        lastCompletedTrail = checkpoint.phase == .flying ? [] : checkpoint.lastCompletedTrail
        cachedTrailsByLevel = checkpoint.cachedTrailsByLevel ?? [:]
        launches = checkpoint.launches
        assisted = checkpoint.assisted
        history = checkpoint.history
        accumulatedTime = checkpoint.accumulatedTime
        flightSteps = checkpoint.flightSteps
        // Gesture and held speed keep their fresh-session defaults.
        refreshPreview()
    }

    private static func checkpointIdentity(_ level: Level) -> Level {
        var identity = level
        identity.answer = [] // Answer UUIDs are regenerated by catalog decoding.
        identity.hint = "" // Teaching copy is not a physics rule; preserve saves across copy fixes.
        return identity
    }

    private static func valid(_ checkpoint: Checkpoint, for level: Level) -> Bool {
        func validPoint(_ point: Vec2) -> Bool {
            // Far beyond this game's world/margin; reject overflow-sized corrupted data.
            point.x.isFinite && point.y.isFinite && abs(point.x) <= 1_000_000 && abs(point.y) <= 1_000_000
        }
        func validTrail(_ trail: [Vec2?], limit: Int = 16_384) -> Bool {
            trail.count <= limit && trail.allSatisfy { $0.map(validPoint) ?? true }
        }
        func validHoles(_ holes: [Hole], selectedID: UUID?) -> Bool {
            guard holes.count <= Physics.holeLimit(for: level),
                  Set(holes.map(\.id)).count == holes.count,
                  selectedID == nil || holes.contains(where: { $0.id == selectedID }),
                  holes.allSatisfy({ hole in
                      validPoint(hole.position) && hole.x >= 0 && hole.x <= Physics.worldWidth
                          && hole.y >= 0 && hole.y <= Physics.worldHeight
                          && hole.mass.isFinite && hole.mass >= Physics.minMass
                          && (hole.mass * 2 == (hole.mass * 2).rounded()
                              || level.answer.contains(where: { $0.mass == hole.mass }))
                  }), holes.reduce(0, { $0 + $1.mass }) <= level.matter + 1e-9 else { return false }
            return holes.allSatisfy { hole in
                Physics.capacityAt(level: level, holes: holes.filter { $0.id != hole.id },
                                   x: hole.x, y: hole.y) + 1e-9 >= hole.mass
            }
        }
        let cachedTrails = checkpoint.cachedTrailsByLevel ?? [:]
        guard cachedTrails.count <= 19,
              cachedTrails[level.name] == nil,
              cachedTrails[checkpoint.levelName] == nil,
              cachedTrails.values.allSatisfy({ validTrail($0, limit: 4096) }) else { return false }
        guard validHoles(checkpoint.holes, selectedID: checkpoint.selectedID),
              checkpoint.launches >= 0, checkpoint.launches < Int.max,
              checkpoint.history.count <= 64,
              checkpoint.history.allSatisfy({ validHoles($0.holes, selectedID: $0.selectedID) && validTrail($0.ghost) }),
              validTrail(checkpoint.trail), validTrail(checkpoint.ghost),
              validTrail(checkpoint.lastCompletedTrail, limit: 4096),
              checkpoint.accumulatedTime.isFinite, checkpoint.accumulatedTime >= 0,
              checkpoint.accumulatedTime < Physics.stepDuration,
              checkpoint.flightSteps >= 0, checkpoint.flightSteps <= 10_802 else { return false }
        if checkpoint.phase == .setup {
            return checkpoint.flight == nil && checkpoint.trail.isEmpty
                && checkpoint.accumulatedTime == 0 && checkpoint.flightSteps == 0
        }
        guard let flight = checkpoint.flight, checkpoint.selectedID == nil,
              (checkpoint.phase == .flying) == (flight.status == .flying),
              flight.time.isFinite, flight.time >= 0, flight.time <= Physics.flightLimit + Physics.stepDuration * 2,
              abs(flight.time - Double(checkpoint.flightSteps) * Physics.stepDuration) <= Physics.stepDuration + 1e-8,
              validPoint(flight.position), validPoint(flight.velocity),
              flight.passed.count == level.beacons.count,
              flight.left == flight.passed.filter({ !$0 }).count,
              flight.status != .won || flight.left == 0,
              flight.jumps >= 0, flight.jumps <= checkpoint.flightSteps,
              flight.closest == .infinity || (flight.closest.isFinite && flight.closest >= 0),
              flight.portal == nil || level.bodies.contains(where: { $0.type == .wormhole && $0.id == flight.portal }),
              flight.reached == nil || level.beacons.contains(flight.reached!) else { return false }
        if checkpoint.phase == .flying {
            guard flight.x >= -Physics.worldMargin, flight.x <= Physics.worldWidth + Physics.worldMargin,
                  flight.y >= -Physics.worldMargin, flight.y <= Physics.worldHeight + Physics.worldMargin else { return false }
        } else if checkpoint.accumulatedTime != 0 { return false }
        if let cause = flight.cause {
            switch cause {
            case .playerHole(let hole): guard checkpoint.holes.contains(hole) else { return false }
            case .body(let body): guard level.bodies.contains(body) else { return false }
            }
        }
        if let jump = flight.jumped {
            guard jump.from.type == .wormhole, jump.to.type == .wormhole,
                  jump.from.twin == jump.to.id,
                  level.bodies.contains(jump.from), level.bodies.contains(jump.to) else { return false }
        }
        return true
    }
}
