import XCTest
@testable import OrbitCore

final class GestureTests: XCTestCase {
    private let center = Vec2(x: 800, y: 450)

    private func level(matter: Double = 80, limit: Int? = nil) -> Level {
        Level(name: "Gesture fixture", matter: matter,
              ship: Ship(x: 100, y: 450, angle: 0, speed: 150),
              goal: Goal(x: 1500, y: 450, r: 36), limit: limit)
    }

    private func place(_ session: GameSession, at point: Vec2? = nil, screenY: Double = 300) {
        XCTAssertTrue(session.begin(at: point ?? center, screenY: screenY, hitRadius: 0))
        session.end()
    }

    func testTouchDownCreatesMinimumHoleAndHoldingDoesNotGrowIt() {
        let session = GameSession(level: level())
        XCTAssertTrue(session.begin(at: center, screenY: 300, hitRadius: 0))
        XCTAssertEqual(session.holes.count, 1)
        XCTAssertEqual(session.holes[0].mass, Physics.minMass)
        session.tick(elapsed: 10)
        session.drag(screenY: 300)
        XCTAssertEqual(session.holes[0].mass, Physics.minMass)
        XCTAssertFalse(session.canUndo)
        session.end()
        XCTAssertTrue(session.canUndo)
    }

    func testUpAndDownResizeWithoutMovingCenterAndUndoWholeGesture() {
        let session = GameSession(level: level())
        XCTAssertTrue(session.begin(at: center, screenY: 300, hitRadius: 0))
        session.drag(screenY: 200)
        XCTAssertEqual(session.holes[0].mass, 37, accuracy: 1e-9)
        session.drag(screenY: 260)
        XCTAssertEqual(session.holes[0].mass, 16, accuracy: 1e-9)
        XCTAssertEqual(session.holes[0].position, center)
        session.end()
        session.undo()
        XCTAssertTrue(session.holes.isEmpty)
        XCTAssertFalse(session.canUndo)
        XCTAssertEqual(session.availableMatter, 80)
    }

    func testResizeClampsToRemainingMatterAndRefundsWhenShrunk() {
        let session = GameSession(level: level(matter: 40))
        place(session, at: Vec2(x: 500, y: 450))
        XCTAssertTrue(session.begin(at: Vec2(x: 1000, y: 450), screenY: 300, hitRadius: 0))
        session.drag(screenY: -1000)
        XCTAssertEqual(session.holes[1].mass, 38, accuracy: 1e-9)
        XCTAssertEqual(session.availableMatter, 0, accuracy: 1e-9)
        session.drag(screenY: 400)
        XCTAssertEqual(session.holes[1].mass, Physics.minMass)
        XCTAssertEqual(session.availableMatter, 36)
        session.end()
    }

    func testResizeClampsToGeometry() {
        let session = GameSession(level: level(matter: 1000))
        let nearEdge = Vec2(x: 800, y: 30)
        let expectedCapacity = Physics.capacityAt(level: session.level, holes: [], x: nearEdge.x, y: nearEdge.y)
        XCTAssertGreaterThan(expectedCapacity, Physics.minMass)
        XCTAssertLessThan(expectedCapacity, 1000)
        XCTAssertTrue(session.begin(at: nearEdge, screenY: 300, hitRadius: 0))
        session.drag(screenY: -10000)
        XCTAssertEqual(session.holes[0].mass, 42.5, accuracy: 1e-9,
                       "Use the largest legal half-step below the geometric capacity")
        XCTAssertLessThanOrEqual(session.holes[0].mass, expectedCapacity)
        XCTAssertLessThanOrEqual(Physics.horizonRadius(mass: session.holes[0].mass), 22 + 1e-9)
    }

    func testTapExistingSelectsWithoutAddingUndoAndDeleteIsUndoable() {
        let session = GameSession(level: level())
        place(session)
        let original = session.holes[0]
        XCTAssertTrue(session.begin(at: center, screenY: 300, hitRadius: 44))
        session.end()
        XCTAssertEqual(session.selectedID, original.id)
        session.deleteSelected()
        XCTAssertTrue(session.holes.isEmpty)
        XCTAssertEqual(session.availableMatter, 80)
        session.undo()
        XCTAssertEqual(session.holes, [original])
        session.undo()
        XCTAssertTrue(session.holes.isEmpty, "A selection tap must not consume an undo step")
        XCTAssertFalse(session.canUndo)
    }

    func testExistingHoleCanResizeWhenHoleCountLimitIsReached() {
        let session = GameSession(level: level(matter: 40, limit: 1))
        place(session)
        XCTAssertFalse(session.begin(at: Vec2(x: 500, y: 450), screenY: 300, hitRadius: 0))
        XCTAssertTrue(session.begin(at: center, screenY: 300, hitRadius: 0))
        session.drag(screenY: 100)
        session.end()
        XCTAssertEqual(session.holes.count, 1)
        XCTAssertEqual(session.holes[0].mass, 40)
        session.undo()
        XCTAssertEqual(session.holes[0].mass, Physics.minMass)
    }

    func testCancellationRollsBackNewAndExistingHolesWithoutHistory() {
        let session = GameSession(level: level())
        XCTAssertTrue(session.begin(at: center, screenY: 300, hitRadius: 0))
        session.drag(screenY: 200)
        session.cancel()
        XCTAssertTrue(session.holes.isEmpty)
        XCTAssertEqual(session.availableMatter, 80)
        XCTAssertFalse(session.canUndo)

        place(session)
        let original = session.holes
        XCTAssertTrue(session.begin(at: center, screenY: 300, hitRadius: 0))
        session.drag(screenY: 200)
        session.cancel()
        XCTAssertEqual(session.holes, original)
        XCTAssertEqual(session.selectedID, original.first?.id)
        session.undo()
        XCTAssertTrue(session.holes.isEmpty)
        XCTAssertFalse(session.canUndo)
    }

    func testInvalidTouchesHaveNoHistoryAndAdditionalTouchCannotReplaceGesture() {
        let session = GameSession(level: level())
        XCTAssertFalse(session.begin(at: session.level.ship.position, screenY: 300, hitRadius: 0))
        XCTAssertFalse(session.begin(at: Vec2(x: -.infinity, y: 20), screenY: 300, hitRadius: 0))
        XCTAssertFalse(session.begin(at: Vec2(x: -1, y: 450), screenY: 300, hitRadius: 1000))
        XCTAssertFalse(session.canUndo)
        XCTAssertTrue(session.holes.isEmpty)
        XCTAssertTrue(session.begin(at: center, screenY: 300, hitRadius: 0))
        let activeID = session.activeHoleID
        XCTAssertFalse(session.begin(at: Vec2(x: 500, y: 450), screenY: 300, hitRadius: 0))
        XCTAssertEqual(session.activeHoleID, activeID)
        session.cancel()
        XCTAssertTrue(session.holes.isEmpty)
        place(session, at: Vec2(x: 25, y: 100))
        XCTAssertFalse(session.begin(at: Vec2(x: -1, y: 100), screenY: 300, hitRadius: 44),
                       "Touch hit slop must not select a hole from outside the board")
        XCTAssertEqual(session.selectedID, session.holes.first?.id, "Invalid input preserves the previous first-placement selection")
    }

    func testResetIsOneUndoableChangeAndLoadClearsHistory() {
        let session = GameSession(level: level())
        place(session, at: Vec2(x: 500, y: 450))
        place(session, at: Vec2(x: 1000, y: 450))
        let original = session.holes
        session.reset()
        XCTAssertTrue(session.holes.isEmpty)
        session.undo()
        XCTAssertEqual(session.holes, original)
        session.load(level: level(matter: 40))
        XCTAssertTrue(session.holes.isEmpty)
        XCTAssertFalse(session.canUndo)
        XCTAssertEqual(session.availableMatter, 40)
    }

    func testLaunchCommitsGestureLocksEditsAndRetryPreservesLayout() {
        let session = GameSession(level: level())
        XCTAssertTrue(session.begin(at: center, screenY: 300, hitRadius: 0))
        session.drag(screenY: 280)
        XCTAssertTrue(session.launch())
        let original = session.holes
        XCTAssertFalse(session.isInteracting)
        XCTAssertFalse(session.begin(at: Vec2(x: 500, y: 450), screenY: 300, hitRadius: 0))
        session.drag(screenY: 0)
        session.undo()
        session.reset()
        session.showSolution()
        session.deleteSelected()
        XCTAssertEqual(session.holes, original)
        session.tick(elapsed: 0.1)
        XCTAssertGreaterThan(session.trail.count, 1)
        session.retry()
        XCTAssertEqual(session.phase, .setup)
        XCTAssertEqual(session.holes, original)
        XCTAssertNil(session.flight)
        XCTAssertFalse(session.ghost.isEmpty)
        session.undo()
        XCTAssertTrue(session.holes.isEmpty)
    }

    func testCancelledAndRevertedResizeRestoreRetryGhost() {
        let session = GameSession(level: level())
        place(session)
        XCTAssertTrue(session.launch())
        session.tick(elapsed: 0.1)
        session.retry()
        let ghost = session.ghost
        XCTAssertFalse(ghost.isEmpty)
        XCTAssertTrue(session.begin(at: center, screenY: 300, hitRadius: 0))
        session.drag(screenY: 200)
        XCTAssertTrue(session.ghost.isEmpty)
        session.cancel()
        XCTAssertEqual(session.ghost, ghost)
        XCTAssertTrue(session.begin(at: center, screenY: 300, hitRadius: 0))
        session.drag(screenY: 200)
        session.drag(screenY: 300)
        session.end()
        XCTAssertEqual(session.ghost, ghost)
        session.undo()
        XCTAssertTrue(session.holes.isEmpty)
    }

    func testSimulationMatchesAcrossDisplayRatesAndPreviewIsFourSeconds() throws {
        let slow = GameSession(level: level())
        let fast = GameSession(level: level())
        XCTAssertEqual(try XCTUnwrap(slow.preview.last ?? nil).x, 700, accuracy: 1e-8)
        XCTAssertTrue(slow.launch())
        XCTAssertTrue(fast.launch())
        for _ in 0..<60 { slow.tick(elapsed: 1.0 / 60) }
        for _ in 0..<120 { fast.tick(elapsed: 1.0 / 120) }
        let slowFlight = try XCTUnwrap(slow.flight)
        let fastFlight = try XCTUnwrap(fast.flight)
        XCTAssertEqual(slowFlight.position, fastFlight.position)
        XCTAssertEqual(slowFlight.time, 1, accuracy: 1e-10)
        XCTAssertEqual(slowFlight.time, fastFlight.time)
        XCTAssertEqual(slow.trail, fast.trail)
    }

    func testBecalmedLaunchRefusesUntilGravityIsAvailable() {
        var fixture = level()
        fixture.ship.speed = 0
        let session = GameSession(level: fixture)
        XCTAssertFalse(session.launch())
        XCTAssertEqual(session.phase, .setup)
        XCTAssertNil(session.flight)
        place(session)
        XCTAssertTrue(session.launch())
    }

    func testSolutionAssistanceRestoresOnUndoAndCancellation() {
        var fixture = level()
        fixture.answer = [Hole(x: center.x, y: center.y, mass: 20)]
        let session = GameSession(level: fixture)
        session.showSolution()
        XCTAssertTrue(session.assisted)
        XCTAssertTrue(session.begin(at: center, screenY: 300, hitRadius: 0))
        session.drag(screenY: 200)
        XCTAssertTrue(session.assisted)
        session.cancel()
        XCTAssertTrue(session.assisted)
        XCTAssertTrue(session.begin(at: center, screenY: 300, hitRadius: 0))
        session.drag(screenY: 200)
        session.end()
        XCTAssertTrue(session.assisted)
        session.undo()
        XCTAssertTrue(session.assisted)
        session.undo()
        XCTAssertFalse(session.assisted)
        XCTAssertTrue(session.holes.isEmpty)
    }

    func testWormholesSeparatePreviewAndTrailSegments() {
        var fixture = level()
        fixture.bodies = [
            Body(type: .wormhole, x: 100, y: 450, r: 30, id: "entry", twin: "exit"),
            Body(type: .wormhole, x: 800, y: 450, r: 30, id: "exit", twin: "entry")
        ]
        let session = GameSession(level: fixture)
        XCTAssertTrue(session.preview.contains(nil))
        XCTAssertTrue(session.launch())
        session.tick(elapsed: 0.1)
        XCTAssertTrue(session.trail.contains(nil))
        XCTAssertEqual(session.flight?.jumps, 1)
    }

    func testFinishedFlightStaysInspectableUntilRetry() {
        var fixture = level()
        fixture.goal = Goal(x: 130, y: 450, r: 36)
        let session = GameSession(level: fixture)
        XCTAssertTrue(session.launch())
        session.tick(elapsed: 0.1)
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.flight?.status, .won)
        let finishTime = session.flight?.time
        session.tick(elapsed: 0.1)
        XCTAssertEqual(session.flight?.time, finishTime)
        XCTAssertFalse(session.begin(at: center, screenY: 300, hitRadius: 0))
        session.retry()
        XCTAssertEqual(session.phase, .setup)
        XCTAssertFalse(session.ghost.isEmpty)
    }
}
