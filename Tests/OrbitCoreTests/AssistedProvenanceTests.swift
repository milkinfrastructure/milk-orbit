import Foundation
import XCTest
@testable import OrbitCore

/// Supplied layouts retain their provenance through edits, undo and restoration.
final class AssistedProvenanceTests: XCTestCase {
    func testEditedSolutionRemainsAssistedEvenWhenReturnedToWinningValues() throws {
        let level = LevelCatalog.all[0], session = GameSession(level: level)
        session.showSolution()
        let original = try XCTUnwrap(session.holes.first)
        XCTAssertTrue(session.begin(at: original.position, screenY: 0, hitRadius: 0)); session.end()
        session.adjustSelected(by: 0.5)
        XCTAssertTrue(session.assisted)
        session.adjustSelected(by: -0.5)
        XCTAssertEqual(session.holes.first?.mass, original.mass)
        XCTAssertTrue(session.assisted, "A +0.5/-0.5 round trip cannot make the supplied solution score-eligible")
        let checkpoint = try JSONDecoder().decode(GameSession.Checkpoint.self, from: JSONEncoder().encode(session.checkpoint()))
        let restored = try GameSession(restoring: checkpoint, level: level)
        XCTAssertTrue(restored.assisted)
        XCTAssertTrue(restored.launch()); restored.setFastForwarding(true)
        for _ in 0..<1000 where restored.phase == .flying { restored.tick(elapsed: 1.0/60) }
        XCTAssertEqual(restored.flight?.status, .won)
        XCTAssertTrue(restored.assisted)
    }

    func testPartialDeleteKeepsAssistanceFinalDeleteClearsAndUndoRestores() throws {
        let session = GameSession(level: LevelCatalog.all[4]) // Two-hole solution.
        session.showSolution()
        let first = try XCTUnwrap(session.holes.first)
        XCTAssertTrue(session.begin(at: first.position, screenY: 0, hitRadius: 0)); session.end()
        session.deleteSelected()
        XCTAssertEqual(session.holes.count, 1); XCTAssertTrue(session.assisted)
        let last = try XCTUnwrap(session.holes.first)
        XCTAssertTrue(session.begin(at: last.position, screenY: 0, hitRadius: 0)); session.end()
        session.deleteSelected()
        XCTAssertTrue(session.holes.isEmpty); XCTAssertFalse(session.assisted)
        session.undo()
        XCTAssertEqual(session.holes.count, 1); XCTAssertTrue(session.assisted)
        session.reset(); XCTAssertFalse(session.assisted)
        session.undo(); XCTAssertTrue(session.assisted)
        session.load(level: LevelCatalog.all[0])
        XCTAssertFalse(session.assisted); XCTAssertTrue(session.holes.isEmpty)
    }

    func testAddedAndMovedHoleDoesNotClearAssistanceAndUndoSolutionRestoresPriorLayout() throws {
        let session = GameSession(level: LevelCatalog.all[0])
        session.showSolution()
        XCTAssertTrue(session.begin(at: Vec2(x: 850, y: 700), screenY: 0, hitRadius: 0)); session.end()
        XCTAssertTrue(session.assisted)
        let added = try XCTUnwrap(session.selectedHole)
        XCTAssertTrue(session.begin(at: added.position, screenY: 0, hitRadius: 0))
        session.move(to: Vec2(x: 900, y: 700)); session.end()
        XCTAssertEqual(session.selectedHole?.position, Vec2(x: 920, y: 720))
        XCTAssertTrue(session.assisted)
        session.undo() // Movement.
        session.undo() // Added hole.
        XCTAssertTrue(session.assisted)
        session.undo() // The entire Show solution action.
        XCTAssertFalse(session.assisted); XCTAssertTrue(session.holes.isEmpty)
    }
}
