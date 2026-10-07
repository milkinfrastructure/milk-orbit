import XCTest
@testable import OrbitCore

final class FlightEventTests: XCTestCase {
    private func level(bodies: [Body] = [], beacons: [Beacon] = [], goal: Goal? = nil) -> Level {
        Level(name: "Event fixture", matter: 40, ship: Ship(x: 100, y: 450, speed: 150),
              goal: goal ?? Goal(x: 1500, y: 450, r: 20), bodies: bodies, beacons: beacons)
    }
    private var portals: [Body] {
        [Body(type: .wormhole, x: 100, y: 450, r: 25, id: "entry", twin: "exit"),
         Body(type: .wormhole, x: 700, y: 450, r: 25, id: "exit", twin: "entry")]
    }
    private func playFirstFrame(_ level: Level, fast: Bool = false) -> (GameSession, [FlightEvent]) {
        let session = GameSession(level: level)
        XCTAssertTrue(session.launch()); session.setFastForwarding(fast)
        session.tick(elapsed: 1.0 / 60)
        return (session, session.drainFlightEvents())
    }

    func testPortalPairAndFollowingImpactSurviveOneRenderedFrameInOrder() {
        let fixture = level(bodies: portals + [Body(type: .asteroid, x: 700, y: 450, r: 20)])
        let (normal, events) = playFirstFrame(fixture)
        let (fast, fastEvents) = playFirstFrame(fixture, fast: true)
        XCTAssertEqual(events.map(\.kind), [.portalEnter, .portalExit, .asteroidImpact])
        XCTAssertEqual(events, fastEvents)
        XCTAssertEqual(normal.flight, fast.flight, "Only observations changed, never collision state")
        XCTAssertEqual(events.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(events[0].position, Vec2(x: 100, y: 450))
        XCTAssertEqual(events[1].position, Vec2(x: 700, y: 450))
        XCTAssertTrue(events.allSatisfy { $0.direction == Vec2(x: 1, y: 0) })
        XCTAssertTrue(events.allSatisfy { $0.simulationTime == Physics.stepDuration })
        XCTAssertTrue(normal.drainFlightEvents().isEmpty)
        normal.tick(elapsed: 1.0 / 60)
        XCTAssertTrue(normal.drainFlightEvents().isEmpty, "A finished frame does not repeat its terminal event")
    }

    func testActualCollisionCausesStayDistinctAndOneShot() {
        let cases: [(BodyType, FlightEvent.Kind, FlightStatus)] = [
            (.hole, .holeCapture, .imploded), (.planet, .planetImpact, .crashed),
            (.asteroid, .asteroidImpact, .crashed), (.repulsor, .repulsorImpact, .crashed)
        ]
        for (type, kind, status) in cases {
            let (session, events) = playFirstFrame(level(bodies: [Body(type: type, x: 100, y: 450, r: 30, mass: 8)]))
            XCTAssertEqual(events.map(\.kind), [kind], "\(type)")
            XCTAssertEqual(session.flight?.status, status)
            XCTAssertTrue(session.drainFlightEvents().isEmpty)
        }
        let fixture = level()
        var withPlayerHole = fixture
        withPlayerHole.answer = [Hole(x: 100, y: 450, mass: 8)]
        let session = GameSession(level: withPlayerHole)
        session.showSolution(); XCTAssertTrue(session.launch()); session.tick(elapsed: 1.0 / 60)
        XCTAssertEqual(session.drainFlightEvents().map(\.kind), [.holeCapture])
        if case .playerHole = session.flight?.cause {} else { XCTFail("Expected real player-hole cause") }
    }

    func testBeaconBeforeDockAndNoEventsFromPredictionOrProximity() {
        let fixture = level(beacons: [Beacon(x: 100, y: 450, r: 30)], goal: Goal(x: 100, y: 450, r: 30))
        let (_, events) = playFirstFrame(fixture)
        XCTAssertEqual(events.map(\.kind), [.beacon, .docked])
        let setup = GameSession(level: level(bodies: portals))
        XCTAssertTrue(setup.drainFlightEvents().isEmpty, "Preview must never emit real flight feedback")
        let (_, near) = playFirstFrame(level(bodies: [Body(type: .planet, x: 100, y: 500, r: 10, mass: 0)]))
        XCTAssertTrue(near.isEmpty, "No inferred collision from visual proximity")
    }

    func testRetryResetLoadAndRestorationCannotReplayBufferedEvents() throws {
        let fixture = level(bodies: portals)
        let session = GameSession(level: fixture)
        XCTAssertTrue(session.launch()); session.tick(elapsed: 1.0 / 60)
        let checkpoint = session.checkpoint()
        let restored = try GameSession(restoring: checkpoint, level: fixture)
        XCTAssertTrue(restored.drainFlightEvents().isEmpty)
        session.retry(); XCTAssertTrue(session.drainFlightEvents().isEmpty)
        XCTAssertTrue(session.launch()); session.tick(elapsed: 1.0 / 60)
        let second = session.drainFlightEvents()
        XCTAssertEqual(second.map(\.sequence), [3, 4], "Sequence stays monotonic through retries")
        session.discardFlightEvents(); XCTAssertTrue(session.drainFlightEvents().isEmpty)
        session.retry(); XCTAssertTrue(session.launch()); session.tick(elapsed: 1.0 / 60)
        session.reset(); XCTAssertTrue(session.drainFlightEvents().isEmpty)
        session.load(level: fixture); XCTAssertTrue(session.drainFlightEvents().isEmpty)
    }

    func testPlannerDedupeMuteAndPortalThenCaptureOrder() {
        let (_, events) = playFirstFrame(level(bodies: portals + [Body(type: .hole, x: 700, y: 450, mass: 8)]))
        var mapper = FlightHapticEventMapper()
        let cues = mapper.consume(events, wallTime: 1)
        XCTAssertEqual(cues, [.init(kind: .portalTransit), .init(kind: .holeCapture, delay: 0.21)])
        XCTAssertTrue(mapper.consume(events, wallTime: 2).isEmpty)
        mapper.resetCadence()
        XCTAssertTrue(mapper.consume(events, wallTime: 3).isEmpty, "Lifecycle must not reset event identity")
        var muted = FlightHapticEventMapper()
        XCTAssertTrue(muted.consume(events, wallTime: 1, enabled: false).isEmpty)
        XCTAssertTrue(muted.consume(events, wallTime: 2).isEmpty, "Unmuting must not replay skipped effects")
    }

    func testPortalCadenceDoesNotSuppressImmediateTerminal() {
        func event(_ sequence: UInt64, _ kind: FlightEvent.Kind) -> FlightEvent {
            FlightEvent(sequence: sequence, kind: kind, simulationTime: 0, position: .zero, direction: .zero)
        }
        var mapper = FlightHapticEventMapper()
        XCTAssertEqual(mapper.consume([event(1, .portalEnter), event(2, .portalExit)], wallTime: 0), [.init(kind: .portalTransit)])
        XCTAssertEqual(mapper.consume([event(3, .portalEnter), event(4, .portalExit), event(5, .planetImpact)], wallTime: 0.1), [.init(kind: .planetImpact)])
        XCTAssertEqual(mapper.consume([event(6, .portalEnter), event(7, .portalExit)], wallTime: 0.33), [.init(kind: .portalTransit)])
        XCTAssertTrue(mapper.consume([event(8, .beacon)], wallTime: 0.35).isEmpty, "Portal envelope suppresses incidental gate chatter")
        XCTAssertTrue(mapper.consume([event(9, .portalExit)], wallTime: 1).isEmpty, "No fabricated pull without a real entrance")
    }

    func testFiniteDistinctRecipesHavePullBeforePopAndCappedEnvelope() {
        for kind in FlightHapticCue.Kind.allCases {
            let recipe = FlightHapticRecipe.recipe(for: kind)
            XCTAssertGreaterThan(recipe.duration, 0)
            XCTAssertLessThanOrEqual(recipe.duration, 0.3)
            for points in [recipe.envelope, recipe.transients] {
                XCTAssertEqual(points.map(\.time), points.map(\.time).sorted())
                XCTAssertTrue(points.allSatisfy { $0.time.isFinite && $0.time >= 0 && (0...0.75).contains($0.intensity) && (0...1).contains($0.sharpness) })
            }
        }
        let portal = FlightHapticRecipe.recipe(for: .portalTransit)
        XCTAssertLessThan(portal.envelope.last!.time, portal.transients.first!.time)
        XCTAssertEqual(portal.envelope.last!.intensity, 0)
        let capture = FlightHapticRecipe.recipe(for: .holeCapture)
        let planet = FlightHapticRecipe.recipe(for: .planetImpact)
        XCTAssertTrue(capture.transients.isEmpty)
        XCTAssertTrue(planet.envelope.isEmpty)
        XCTAssertNotEqual(capture, planet)
    }
}
