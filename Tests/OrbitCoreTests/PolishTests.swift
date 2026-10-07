import XCTest
@testable import OrbitCore

final class PolishTests: XCTestCase {
    func testQuadrupleSpeedKeepsEveryLevelTrajectoryAndCollisionResult() {
        for level in LevelCatalog.all {
            // Supplied solutions plus unassisted routes cover wins, collisions and portals.
            for assisted in [false, true] {
                let normal = GameSession(level: level), fast = GameSession(level: level)
                if assisted { normal.showSolution(); fast.showSolution() }
                guard normal.launch() else { XCTAssertFalse(fast.launch()); continue }
                XCTAssertTrue(fast.launch())
                fast.setFastForwarding(true)
                for _ in 0..<1500 where normal.phase == .flying {
                    for _ in 0..<4 { normal.tick(elapsed: 1.0 / 60) }
                    fast.tick(elapsed: 1.0 / 60)
                    XCTAssertEqual(normal.flight, fast.flight, level.name)
                    XCTAssertEqual(normal.trail, fast.trail, level.name)
                }
                XCTAssertEqual(normal.phase, .finished, level.name)
                XCTAssertEqual(fast.phase, .finished, level.name)
                XCTAssertFalse(fast.isFastForwarding)
            }
        }
    }

    func testSpeedReleaseSuspensionClampAndLifecycle() {
        let level = LevelCatalog.all[0]
        let session = GameSession(level: level)
        session.setFastForwarding(true)
        XCTAssertFalse(session.isFastForwarding)
        XCTAssertTrue(session.launch())
        session.setFastForwarding(true)
        session.tick(elapsed: 10) // Only 0.1 wall seconds, or 0.4 simulated seconds.
        XCTAssertEqual(session.flight!.time, 0.4, accuracy: 1e-9)
        session.setFastForwarding(false)
        session.tick(elapsed: 0.1)
        XCTAssertEqual(session.flight!.time, 0.5, accuracy: 1e-9)
        session.setFastForwarding(true)
        session.retry()
        XCTAssertFalse(session.isFastForwarding)
        XCTAssertTrue(session.launch())
        session.setFastForwarding(true)
        session.load(level: level)
        XCTAssertFalse(session.isFastForwarding)
    }

    func testGridMoveKeepsMassRejectsIllegalPositionsAndIsOneUndo() {
        let session = GameSession(level: LevelCatalog.all[0])
        XCTAssertTrue(session.begin(at: Vec2(x: 800, y: 450), screenY: 100, hitRadius: 0))
        session.end()
        let original = session.holes[0]
        XCTAssertEqual(session.selectedID, original.id, "First placement immediately exposes editing")
        XCTAssertTrue(session.begin(at: original.position, screenY: 100, hitRadius: 0))
        session.move(to: Vec2(x: 900, y: 500))
        session.move(to: Vec2(x: 1000, y: 300))
        XCTAssertEqual(session.holes[0].position, Vec2(x: 1000, y: 320))
        XCTAssertEqual(session.holes[0].mass, original.mass)
        for invalid in [session.level.ship.position, Vec2(x: .nan, y: 400)] {
            session.move(to: invalid)
            XCTAssertEqual(session.holes[0].position, Vec2(x: 1000, y: 320))
        }
        session.end()
        session.undo()
        XCTAssertEqual(session.holes, [original])
        XCTAssertTrue(session.begin(at: original.position, screenY: 100, hitRadius: 0))
        session.move(to: Vec2(x: 950, y: 500))
        session.cancel()
        XCTAssertEqual(session.holes, [original])
    }

    func testRapidTapTransactionsAndLargeHitTargetStayConsistent() {
        let session = GameSession(level: LevelCatalog.all[0])
        for _ in 0..<100 {
            XCTAssertTrue(session.begin(at: Vec2(x: 800, y: 450), screenY: 100, hitRadius: 60))
            session.end()
            XCTAssertEqual(session.holes.count, 1)
            XCTAssertEqual(session.availableMatter, 38)
        }
        session.deleteSelected()
        XCTAssertTrue(session.holes.isEmpty)
        session.undo()
        XCTAssertEqual(session.holes.count, 1)
        XCTAssertEqual(session.availableMatter, 38)
    }
}
