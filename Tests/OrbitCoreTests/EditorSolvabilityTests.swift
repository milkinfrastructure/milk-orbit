import Foundation
import XCTest
@testable import OrbitCore

/// Extra fixtures for the current editor; original catalog answers/reference physics remain untouched.
final class EditorSolvabilityTests: XCTestCase {
    private struct Candidate: Decodable {
        struct Placement: Decodable { let x: Double, y: Double, mass: Double }
        let levelIndex: Int
        let name: String
        let holes: [Placement]
        let simulationTime: Double
        let portalJumps: Int
    }
    private func fixtures() throws -> [Candidate] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "editor-solutions", withExtension: "json"))
        return try JSONDecoder().decode([Candidate].self, from: Data(contentsOf: url))
    }
    private func build(_ fixture: Candidate, level: Level) throws -> GameSession {
        let session = GameSession(level: level)
        for target in fixture.holes {
            XCTAssertTrue(target.x.isFinite && target.y.isFinite && target.mass.isFinite)
            XCTAssertGreaterThanOrEqual(target.mass, Physics.minMass)
            XCTAssertEqual(target.mass * 2, (target.mass * 2).rounded(), accuracy: 1e-9)
            session.clearSelection()
            let count = session.holes.count
            XCTAssertTrue(session.begin(at: Vec2(x: target.x, y: target.y), screenY: 0, hitRadius: 0), fixture.name)
            session.end()
            XCTAssertEqual(session.holes.count, count + 1, "Each initial tap must place a distinct hole")
            for _ in 0..<Int((target.mass - Physics.minMass) * 2) { session.adjustSelected(by: 0.5) }
            let actual = try XCTUnwrap(session.selectedHole)
            XCTAssertEqual(actual.position, Vec2(x: target.x, y: target.y))
            XCTAssertEqual(actual.mass, target.mass)
            XCTAssertFalse(session.assisted, "Never call showSolution to construct an ordinary editor fixture")
        }
        XCTAssertLessThanOrEqual(session.holes.count, Physics.holeLimit(for: level))
        XCTAssertLessThanOrEqual(session.holes.reduce(0) { $0 + $1.mass }, level.matter + 1e-9)
        for hole in session.holes {
            let others = session.holes.filter { $0.id != hole.id }
            XCTAssertGreaterThanOrEqual(Physics.capacityAt(level: level, holes: others, x: hole.x, y: hole.y) + 1e-9, hole.mass)
        }
        return session
    }

    func testAllTwentySectorsWinFromOrdinaryPlacementAndHalfStepButtons() throws {
        let fixtures = try fixtures(), levels = LevelCatalog.all
        XCTAssertEqual(fixtures.count, 20)
        XCTAssertEqual(Set(fixtures.map(\.levelIndex)), Set(levels.indices))
        for fixture in fixtures {
            let level = levels[fixture.levelIndex]
            XCTAssertEqual(fixture.name, level.name)
            let originalAnswer = level.answer
            let session = try build(fixture, level: level)
            let result = Physics.fly(level: level, holes: session.holes)
            XCTAssertEqual(result.status, .won, fixture.name)
            XCTAssertEqual(result.left, 0, fixture.name)
            XCTAssertEqual(result.time, fixture.simulationTime, accuracy: 1e-9, fixture.name)
            XCTAssertEqual(result.jumps, fixture.portalJumps, fixture.name)
            XCTAssertEqual(level.answer, originalAnswer, "Additional editor fixtures must not overwrite original answers")
        }
    }

    func testEditorWinningLayoutsPreserveOneAndFourTimesTrajectoryAndCheckpoint() throws {
        for fixture in try fixtures() {
            let level = LevelCatalog.all[fixture.levelIndex]
            let normal = try build(fixture, level: level)
            // A checkpoint clone keeps the same player-hole identities, avoiding fixture assignment.
            let encoded = try JSONEncoder().encode(normal.checkpoint())
            let checkpoint = try JSONDecoder().decode(GameSession.Checkpoint.self, from: encoded)
            let fast = try GameSession(restoring: checkpoint, level: level)
            XCTAssertFalse(fast.assisted)
            XCTAssertTrue(normal.launch()); XCTAssertTrue(fast.launch())
            fast.setFastForwarding(true)
            for _ in 0..<1000 where normal.phase == .flying {
                for _ in 0..<4 { normal.tick(elapsed: 1.0 / 60) }
                fast.tick(elapsed: 1.0 / 60)
                XCTAssertEqual(normal.flight, fast.flight, fixture.name)
                XCTAssertEqual(normal.trail, fast.trail, fixture.name)
            }
            XCTAssertEqual(normal.flight?.status, .won, fixture.name)
            XCTAssertEqual(fast.flight?.status, .won, fixture.name)
            XCTAssertFalse(normal.assisted); XCTAssertFalse(fast.assisted)
            XCTAssertFalse(fast.isFastForwarding)
        }
    }
}
