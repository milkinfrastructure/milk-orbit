import XCTest
@testable import OrbitCore

/// Core transitions behind Next/Replay/Start over; these do not exercise UIKit buttons.
final class SectorTransitionTests: XCTestCase {
    private func winWithSuppliedSolution(_ session: GameSession) {
        session.showSolution()
        XCTAssertTrue(session.launch())
        session.setFastForwarding(true)
        for _ in 0..<500 where session.phase == .flying { session.tick(elapsed: 0.1) }
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.flight?.status, .won, session.level.name)
        XCTAssertFalse(session.lastCompletedTrail.isEmpty)
        XCTAssertFalse(session.isFastForwarding)
    }

    func testFirstWinThenSecondSectorRetryResetKeepsWorldAndUndoInSecondSector() throws {
        let levels = LevelCatalog.all
        XCTAssertEqual(levels.count, 20)
        let first = levels[0], second = levels[1]
        let session = GameSession(level: first)
        winWithSuppliedSolution(session)
        let firstTrail = session.lastCompletedTrail

        session.load(level: second)
        XCTAssertEqual(session.level, second)
        XCTAssertEqual(session.phase, .setup)
        XCTAssertNil(session.flight)
        XCTAssertTrue(session.holes.isEmpty)
        XCTAssertEqual(session.availableMatter, second.matter)
        XCTAssertEqual(session.launches, 0)
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.isInteracting)
        XCTAssertFalse(session.isFastForwarding)
        XCTAssertTrue(session.trail.isEmpty)
        XCTAssertTrue(session.ghost.isEmpty)
        XCTAssertTrue(session.lastCompletedTrail.isEmpty)
        XCTAssertTrue(session.drainFlightEvents().isEmpty)
        XCTAssertEqual(try XCTUnwrap(session.preview.first ?? nil), second.ship.position)
        // A setup retry/reset is harmless; the first sector's winning layout must not return.
        session.retry(); session.reset()
        XCTAssertTrue(session.holes.isEmpty)
        XCTAssertFalse(session.canUndo)

        session.showSolution()
        let secondHoles = session.holes
        XCTAssertEqual(secondHoles, second.answer)
        XCTAssertTrue(session.launch())
        session.setFastForwarding(true)
        session.tick(elapsed: 0.0123)
        XCTAssertEqual(session.phase, .flying)
        session.retry()
        XCTAssertEqual(session.phase, .setup)
        XCTAssertNil(session.flight)
        XCTAssertFalse(session.isFastForwarding)
        XCTAssertEqual(session.holes, secondHoles)
        XCTAssertTrue(session.drainFlightEvents().isEmpty)
        session.reset()
        XCTAssertTrue(session.holes.isEmpty)
        XCTAssertEqual(session.availableMatter, second.matter)
        XCTAssertEqual(session.launches, 1)
        session.undo()
        XCTAssertEqual(session.holes, secondHoles, "Reset undo must restore only the new sector's layout")
        XCTAssertEqual(session.level, second)
        XCTAssertTrue(session.lastCompletedTrail.isEmpty)

        session.load(level: first)
        XCTAssertEqual(session.lastCompletedTrail, firstTrail, "Next must retain the preceding sector's reference route")
        XCTAssertTrue(session.holes.isEmpty)
    }

    func testFinalCatalogWinCanReplayAndLoadFirstWithoutLeakingFlightState() throws {
        let levels = LevelCatalog.all
        XCTAssertEqual(levels.count, 20)
        let first = try XCTUnwrap(levels.first), final = try XCTUnwrap(levels.last)
        let session = GameSession(level: final)
        winWithSuppliedSolution(session)
        let finalTrail = session.lastCompletedTrail, finalHoles = session.holes
        session.retry()
        XCTAssertEqual(session.level, final)
        XCTAssertEqual(session.holes, finalHoles)
        XCTAssertEqual(session.lastCompletedTrail, finalTrail)
        XCTAssertEqual(session.phase, .setup)
        XCTAssertNil(session.flight)
        XCTAssertTrue(session.drainFlightEvents().isEmpty)
        XCTAssertEqual(try XCTUnwrap(session.preview.first ?? nil), final.ship.position)
        // Ordinary navigation to the first sector preserves the campaign's routes.
        session.load(level: first)
        XCTAssertEqual(session.level, first)
        XCTAssertEqual(session.phase, .setup)
        XCTAssertNil(session.flight)
        XCTAssertTrue(session.holes.isEmpty)
        XCTAssertEqual(session.availableMatter, first.matter)
        XCTAssertEqual(session.launches, 0)
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.assisted)
        XCTAssertFalse(session.isFastForwarding)
        XCTAssertTrue(session.trail.isEmpty)
        XCTAssertTrue(session.ghost.isEmpty)
        XCTAssertTrue(session.lastCompletedTrail.isEmpty)
        XCTAssertEqual(try XCTUnwrap(session.preview.first ?? nil), first.ship.position)
        session.retry(); session.reset()
        XCTAssertTrue(session.holes.isEmpty)
        session.load(level: final)
        XCTAssertEqual(session.lastCompletedTrail, finalTrail)
        XCTAssertTrue(session.holes.isEmpty)
    }
}
