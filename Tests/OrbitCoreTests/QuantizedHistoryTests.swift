import XCTest
@testable import OrbitCore

final class QuantizedHistoryTests: XCTestCase {
    private func fixture(matter: Double = 80) -> Level {
        Level(name: "Half-step and history fixture", matter: matter,
              ship: Ship(x: 100, y: 450, speed: 150), goal: Goal(x: 1500, y: 450, r: 24))
    }

    private func place(_ session: GameSession, at point: Vec2) {
        XCTAssertTrue(session.begin(at: point, screenY: 0, hitRadius: 0))
        session.end()
    }

    private func complete(_ session: GameSession) {
        XCTAssertTrue(session.launch())
        for _ in 0..<500 where session.phase == .flying { session.tick(elapsed: 0.1) }
        XCTAssertEqual(session.phase, .finished)
        XCTAssertFalse(session.lastCompletedTrail.isEmpty)
    }

    func testHeldStrengthCommitsOnceAndScrollCancellationLeavesNoUndoEntry() {
        let s = GameSession(level: fixture())
        place(s, at: Vec2(x:800,y:100))
        XCTAssertTrue(s.begin(at:s.holes[0].position,screenY:0,hitRadius:0))
        for mass in [2.5,3.0,3.5] { s.setStrength(mass) }
        s.cancel()
        XCTAssertEqual(s.holes[0].mass,2)
        s.undo()
        XCTAssertTrue(s.holes.isEmpty, "Scrolling must not leave a phantom strength edit in history")
        place(s, at:Vec2(x:800,y:100))
        XCTAssertTrue(s.begin(at:s.holes[0].position,screenY:0,hitRadius:0))
        for mass in [2.5,3.0,3.5] { s.setStrength(mass) }
        s.end(); s.undo()
        XCTAssertEqual(s.holes[0].mass,2,"One undo reverses the whole held adjustment")
    }

    func testBothDragPathsCrossHalfStepThresholdsWithoutQuarterValues() {
        for precise in [false, true] {
            let s = GameSession(level: fixture())
            XCTAssertTrue(s.begin(at: Vec2(x: 800, y: 100), screenY: 0, hitRadius: 0))
            for (requested, expected) in [(2.24, 2.0), (2.26, 2.5), (2.74, 2.5),
                                          (2.76, 3.0), (2.24, 2.0)] {
                if precise { s.dragPrecisely(screenY: -50 * log(requested / 2)) }
                else { s.drag(screenY: -(requested - 2) / GameSession.massPerScreenPoint) }
                XCTAssertEqual(s.holes[0].mass, expected, accuracy: 1e-9)
                XCTAssertEqual(s.holes[0].mass * 2, (s.holes[0].mass * 2).rounded())
            }
            s.end()
            s.undo()
            XCTAssertTrue(s.holes.isEmpty, "The complete touch remains one transaction")
        }
    }

    func testHalfStepsStayBelowFractionalBudgetAndGeometricCaps() {
        let s = GameSession(level: fixture(matter: 8.3))
        place(s, at: Vec2(x: 500, y: 100))
        place(s, at: Vec2(x: 1000, y: 100))
        s.adjustSelected(by: 1000)
        XCTAssertEqual(s.holes[1].mass, 6)
        XCTAssertEqual(s.availableMatter, 0.3, accuracy: 1e-9)
        s.adjustSelected(by: 0.5)
        XCTAssertEqual(s.holes[1].mass, 6, "No partial step may consume the final 0.3")
        for _ in 0..<20 { s.adjustSelected(by: -0.5) }
        XCTAssertEqual(s.holes[1].mass, 2)
        XCTAssertEqual(s.availableMatter, 4.3, accuracy: 1e-9)

        for precise in [false, true] {
            let edge = GameSession(level: fixture(matter: 1000))
            XCTAssertTrue(edge.begin(at: Vec2(x: 800, y: 30), screenY: 0, hitRadius: 0))
            if precise { edge.dragPrecisely(screenY: -.greatestFiniteMagnitude) }
            else { edge.drag(screenY: -.greatestFiniteMagnitude) }
            XCTAssertEqual(edge.holes[0].mass, 42.5)
            XCTAssertLessThanOrEqual(Physics.horizonRadius(mass: edge.holes[0].mass) + Physics.clearance, 30)
            XCTAssertGreaterThan(Physics.horizonRadius(mass: edge.holes[0].mass + 0.5) + Physics.clearance, 30)
        }
    }

    func testSubstepEditsAndRepeatedClampDoNotAddUndoEntries() {
        let s = GameSession(level: fixture(matter: 2))
        place(s, at: Vec2(x: 800, y: 100))
        for _ in 0..<20 { s.adjustSelected(by: 0.5); s.adjustSelected(by: -0.5) }
        XCTAssertEqual(s.holes[0].mass, 2)
        XCTAssertTrue(s.begin(at: s.holes[0].position, screenY: 0, hitRadius: 0))
        s.dragPrecisely(screenY: -1)
        s.end()
        s.undo()
        XCTAssertTrue(s.holes.isEmpty)
        XCTAssertFalse(s.canUndo)
    }

    func testMovementSnapsOnlyMovesAndRemainsOneUndo() {
        let s = GameSession(level: fixture())
        let placed = Vec2(x: 817, y: 443)
        place(s, at: placed)
        let original = s.holes[0]
        XCTAssertEqual(original.position, placed, "Placement stays at the tapped point")
        XCTAssertTrue(s.begin(at: placed, screenY: 0, hitRadius: 0))
        s.move(to: Vec2(x: 799, y: 459))
        XCTAssertEqual(s.holes[0].position, Vec2(x: 800, y: 440))
        let unchangedPreview = s.preview
        s.move(to: Vec2(x: 819.9, y: 459.9))
        XCTAssertEqual(s.holes[0].position, Vec2(x: 800, y: 440))
        XCTAssertEqual(s.preview, unchangedPreview)
        s.move(to: Vec2(x: 820.1, y: 460.1))
        XCTAssertEqual(s.holes[0].position, Vec2(x: 840, y: 480))
        XCTAssertEqual(s.holes[0].mass, original.mass)
        s.end()
        s.undo()
        XCTAssertEqual(s.holes, [original])
        s.undo()
        XCTAssertTrue(s.holes.isEmpty)
    }

    func testMovementValidatesTheSnappedDestination() {
        var level = fixture()
        level.zones = [Zone(x: 844, y: 434, w: 8, h: 12)]
        let s = GameSession(level: level)
        place(s, at: Vec2(x: 600, y: 600))
        let original = s.holes[0]
        let raw = Vec2(x: 821, y: 421)
        XCTAssertGreaterThanOrEqual(Physics.capacityAt(level: level, holes: [], x: raw.x, y: raw.y), original.mass)
        XCTAssertEqual(Physics.capacityAt(level: level, holes: [], x: 840, y: 440), 0)
        XCTAssertTrue(s.begin(at: original.position, screenY: 0, hitRadius: 0))
        s.move(to: raw)
        XCTAssertEqual(s.holes, [original])
        XCTAssertNotNil(s.lastFeedback)
        s.end()
        s.undo()
        XCTAssertTrue(s.holes.isEmpty, "Rejected movement adds no undo entry")
    }

    func testCompletedHistorySurvivesEditsUntilNextAcceptedLaunch() {
        let s = GameSession(level: fixture())
        complete(s)
        let completed = s.lastCompletedTrail
        XCTAssertEqual(completed, s.trail)
        s.retry()
        place(s, at: Vec2(x: 800, y: 100))
        XCTAssertEqual(s.lastCompletedTrail, completed)
        s.adjustSelected(by: 0.5)
        XCTAssertEqual(s.lastCompletedTrail, completed)
        XCTAssertTrue(s.begin(at: s.holes[0].position, screenY: 0, hitRadius: 0))
        s.move(to: Vec2(x: 700, y: 200))
        s.cancel()
        XCTAssertEqual(s.lastCompletedTrail, completed)
        s.deleteSelected()
        s.undo()
        XCTAssertEqual(s.lastCompletedTrail, completed)
        XCTAssertTrue(s.launch())
        XCTAssertTrue(s.lastCompletedTrail.isEmpty, "An accepted launch clears the previous run immediately")
        s.tick(elapsed: 0.1)
        XCTAssertEqual(s.phase, .flying)
        XCTAssertTrue(s.lastCompletedTrail.isEmpty)
        s.retry()
        XCTAssertTrue(s.lastCompletedTrail.isEmpty, "Aborting does not resurrect the prior run cleared on launch")
        complete(s)
        XCTAssertEqual(s.lastCompletedTrail, s.trail)
        XCTAssertNotEqual(s.lastCompletedTrail, completed, "The next completed run replaces history")
    }

    func testResetPreservesTrailAndLevelSwitchRestoresEachSector() {
        let first = fixture()
        let s = GameSession(level: first)
        complete(s)
        let completed = s.lastCompletedTrail
        s.retry()
        XCTAssertTrue(s.holes.isEmpty)
        s.reset()
        XCTAssertEqual(s.lastCompletedTrail, completed)
        place(s, at: Vec2(x: 800, y: 100))
        s.reset()
        XCTAssertTrue(s.holes.isEmpty)
        XCTAssertEqual(s.lastCompletedTrail, completed)
        s.undo()
        XCTAssertEqual(s.lastCompletedTrail, completed)
        var other = fixture(matter: 40)
        other.name = "Another sector"
        s.load(level: other)
        XCTAssertTrue(s.lastCompletedTrail.isEmpty && s.trail.isEmpty && s.ghost.isEmpty)
        XCTAssertEqual(s.phase, .setup)
        s.load(level: first)
        XCTAssertEqual(s.lastCompletedTrail, completed)
    }

    func testHistoryKeepsPortalSeparatorsAndLongestOrdinaryRunIsBounded() {
        var portals = fixture()
        portals.bodies = [Body(type: .wormhole, x: 100, y: 450, r: 30, id: "a", twin: "b"),
                          Body(type: .wormhole, x: 800, y: 450, r: 30, id: "b", twin: "a")]
        portals.goal = Goal(x: 900, y: 450, r: 20)
        let portalSession = GameSession(level: portals)
        complete(portalSession)
        XCTAssertTrue(portalSession.lastCompletedTrail.contains(nil))
        XCTAssertEqual(portalSession.lastCompletedTrail, portalSession.trail)

        var slow = fixture()
        slow.ship.speed = 0.01
        let session = GameSession(level: slow)
        complete(session)
        XCTAssertEqual(session.flight?.status, .stranded)
        XCTAssertGreaterThan(session.lastCompletedTrail.count, 3500)
        XCTAssertLessThanOrEqual(session.lastCompletedTrail.count, 4096)
        XCTAssertEqual(session.lastCompletedTrail, session.trail)
    }
}
