import Foundation
import XCTest
@testable import OrbitCore

/// Campaign restart is destructive; ordinary Reset, Retry, and sector navigation are not.
/// These tests cover core/store semantics, not UIKit confirmation or process-restart input.
final class CampaignResetTests: XCTestCase {
    private func win(_ session: GameSession, file: StaticString = #filePath, line: UInt = #line) {
        session.showSolution()
        XCTAssertTrue(session.launch(), file: file, line: line)
        session.setFastForwarding(true)
        for _ in 0..<500 where session.phase == .flying { session.tick(elapsed: 0.1) }
        XCTAssertEqual(session.flight?.status, .won, session.level.name, file: file, line: line)
        XCTAssertFalse(session.lastCompletedTrail.isEmpty, file: file, line: line)
    }

    private func restored(_ session: GameSession) throws -> GameSession {
        let data = try JSONEncoder().encode(session.checkpoint())
        let checkpoint = try JSONDecoder().decode(GameSession.Checkpoint.self, from: data)
        return try GameSession(restoring: checkpoint, level: session.level)
    }

    private func assertFresh(_ session: GameSession, at level: Level,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(session.level, level, file: file, line: line)
        XCTAssertEqual(session.phase, .setup, file: file, line: line)
        XCTAssertEqual(session.availableMatter, level.matter, file: file, line: line)
        XCTAssertEqual(session.remainingHoleSlots, session.holeLimit, file: file, line: line)
        XCTAssertTrue(session.holes.isEmpty, file: file, line: line)
        XCTAssertNil(session.selectedID, file: file, line: line)
        XCTAssertNil(session.flight, file: file, line: line)
        XCTAssertEqual(session.launches, 0, file: file, line: line)
        XCTAssertFalse(session.canUndo, file: file, line: line)
        XCTAssertFalse(session.assisted, file: file, line: line)
        XCTAssertFalse(session.isInteracting, file: file, line: line)
        XCTAssertFalse(session.isFastForwarding, file: file, line: line)
        XCTAssertTrue(session.trail.isEmpty, file: file, line: line)
        XCTAssertTrue(session.ghost.isEmpty, file: file, line: line)
        XCTAssertTrue(session.lastCompletedTrail.isEmpty, file: file, line: line)
        XCTAssertNil(session.lastFeedback, file: file, line: line)
        XCTAssertEqual(session.preview.first ?? nil, level.ship.position, file: file, line: line)
        XCTAssertTrue(session.drainFlightEvents().isEmpty, file: file, line: line)
    }

    func testFinalVictoryRestartReturnsInitialBudgetAndCannotUndoIntoOldCampaign() throws {
        let levels = LevelCatalog.all
        let first = try XCTUnwrap(levels.first), final = try XCTUnwrap(levels.last)
        let session = GameSession(level: final)
        win(session)
        XCTAssertTrue(try XCTUnwrap(FlightRecord(session: session,
            sectorIndex: levels.count - 1, sectorCount: levels.count)).isFinalSector)

        session.restartCampaign(at: first)
        assertFresh(session, at: first)
        XCTAssertNil(FlightRecord(session: session, sectorIndex: 0, sectorCount: levels.count))
        session.undo()
        session.retry()
        session.reset()
        assertFresh(session, at: first)
        assertFresh(try restored(session), at: first)
    }

    func testRestartErasesActiveAndCachedRoutesAcrossCheckpointRoundTripAndRevisit() throws {
        let levels = LevelCatalog.all
        let first = try XCTUnwrap(levels.first), final = try XCTUnwrap(levels.last)
        let original = GameSession(level: first)
        win(original)
        original.load(level: final)
        win(original)

        // Establish that both routes really survive normal checkpoint restoration/navigation.
        let session = try restored(original)
        XCTAssertFalse(session.lastCompletedTrail.isEmpty)
        session.load(level: first)
        XCTAssertFalse(session.lastCompletedTrail.isEmpty)
        session.load(level: final)
        XCTAssertFalse(session.lastCompletedTrail.isEmpty)

        session.restartCampaign(at: first)
        let resetSave = try restored(session)
        assertFresh(resetSave, at: first)
        resetSave.load(level: final)
        assertFresh(resetSave, at: final)
        resetSave.load(level: first)
        assertFresh(resetSave, at: first)
    }

    func testRestartDuringGestureIgnoresLateTouchCompletionAndAcceptsNewEditing() throws {
        let oldLevel = Level(name: "Restart gesture fixture", matter: 80,
                             ship: Ship(x: 100, y: 450, speed: 150),
                             goal: Goal(x: 1500, y: 450, r: 36))
        let first = try XCTUnwrap(LevelCatalog.all.first)
        let session = GameSession(level: oldLevel)
        XCTAssertTrue(session.begin(at: Vec2(x: 800, y: 450), screenY: 300, hitRadius: 0))
        session.drag(screenY: 200)
        XCTAssertTrue(session.isInteracting)
        XCTAssertLessThan(session.availableMatter, oldLevel.matter)

        session.restartCampaign(at: first)
        // A recognizer cancellation or delayed touch-up must not restore its old snapshot.
        session.cancel()
        session.end()
        session.undo()
        assertFresh(session, at: first)

        let legalPoint = try XCTUnwrap(first.answer.first).position
        XCTAssertTrue(session.begin(at: legalPoint, screenY: 300, hitRadius: 0))
        session.end()
        XCTAssertEqual(session.holes.count, 1)
        XCTAssertTrue(session.canUndo)
        session.undo()
        assertFresh(session, at: first)
    }

    func testRestartDuringFastFlightIsIdempotentAndNextFlightStartsWithFreshIntegrator() throws {
        let first = try XCTUnwrap(LevelCatalog.all.first)
        let session = GameSession(level: first)
        session.showSolution()
        XCTAssertTrue(session.launch())
        session.setFastForwarding(true)
        session.tick(elapsed: 0.0017) // Nonzero fixed-step remainder before interruption.
        XCTAssertEqual(session.phase, .flying)
        XCTAssertTrue(session.isFastForwarding)

        session.restartCampaign(at: first)
        session.restartCampaign(at: first)
        session.setFastForwarding(false) // Late button release is harmless.
        assertFresh(session, at: first)

        let fresh = GameSession(level: first)
        session.showSolution()
        fresh.showSolution()
        XCTAssertTrue(session.launch())
        XCTAssertTrue(fresh.launch())
        for elapsed in [0.001, 0.003, 0.013, 0.0167] {
            session.tick(elapsed: elapsed)
            fresh.tick(elapsed: elapsed)
            XCTAssertEqual(session.flight, fresh.flight)
            XCTAssertEqual(session.trail, fresh.trail)
        }
        XCTAssertEqual(session.launches, 1)
    }

    func testCampaignStoreResetClearsProgressButPreservesPreferencesAndUnrelatedKeys() throws {
        let suite = "MilkOrbit.CampaignResetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preserved: [String: Any] = [
            "orbit.hapticsMuted": true,
            "orbit.editTutorialShown.v2": true,
            "orbit.strengthLearned": true,
            "orbit.moveLearned": true,
            "orbit.futurePreference": "keep",
            "orbit.best.holesHint": "not a sector record",
            "unrelated.sentinel": Data([9, 8, 7])
        ]
        for (key, value) in preserved { defaults.set(value, forKey: key) }
        defaults.set(19, forKey: "orbit.current")
        defaults.set(19, forKey: "orbit.unlocked")
        defaults.set(Data([1, 2, 3]), forKey: "orbit.checkpoint.v1")
        defaults.set(Data([4, 5, 6]), forKey: "orbit.checkpoint.recovery.v1")
        defaults.set(Data([6, 5, 4]), forKey: "orbit.checkpoint.catalogRecovery.v1")
        defaults.set(Data([7, 8, 9]), forKey: "orbit.lastVictory.v1")
        defaults.set(true, forKey: "orbit.finalePresented.v1")
        for index in 0..<20 {
            defaults.set(1, forKey: "orbit.best.holes.\(index)")
            defaults.set(2.5, forKey: "orbit.best.matter.\(index)")
            defaults.set("Docking confirmed.", forKey: "orbit.lastOutcome.\(index)")
        }

        CampaignProgress.reset(in: defaults)
        CampaignProgress.reset(in: defaults)

        // A new defaults handle verifies the stored domain rather than controller variables.
        let reader = try XCTUnwrap(UserDefaults(suiteName: suite))
        var expected = preserved
        expected["orbit.current"] = 0
        expected["orbit.unlocked"] = 0
        let actual = try XCTUnwrap(reader.persistentDomain(forName: suite))
        XCTAssertEqual(NSDictionary(dictionary: actual), NSDictionary(dictionary: expected))
    }
}
