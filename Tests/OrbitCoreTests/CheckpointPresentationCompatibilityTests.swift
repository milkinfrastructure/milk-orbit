import Foundation
import XCTest
@testable import OrbitCore

/// Version-1 saves survive presentation changes without accepting different rules.
final class CheckpointPresentationCompatibilityTests: XCTestCase {
    private func legacyCheckpoint(_ session: GameSession) throws -> GameSession.Checkpoint {
        let data = try JSONEncoder().encode(session.checkpoint())
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var level = try XCTUnwrap(root["level"] as? [String: Any])
        // Old version-1 checkpoints stored hint verbatim; a new exporter cannot recreate this by itself.
        level["hint"] = "Press and hold to grow a black hole, then launch. Its pull will bend the ship's course."
        root["level"] = level
        return try JSONDecoder().decode(GameSession.Checkpoint.self, from: JSONSerialization.data(withJSONObject: root))
    }

    func testLegacyFirstLightHintRestoresExactFlightUnderCurrentCatalogCopy() throws {
        var level = LevelCatalog.all[0]
        level.hint = "Updated instructions: hold, then drag vertically to change strength."
        let original = GameSession(level: level)
        XCTAssertTrue(original.begin(at: Vec2(x: 581, y: 496), screenY: 0, hitRadius: 0))
        original.setStrength(8); original.end()
        XCTAssertTrue(original.launch()); original.setFastForwarding(true)
        original.tick(elapsed: 0.0173)
        let restored = try GameSession(restoring: legacyCheckpoint(original), level: level)
        XCTAssertEqual(restored.level.hint, level.hint, "The catalog supplies current presentation text")
        XCTAssertEqual(restored.holes, original.holes)
        XCTAssertEqual(restored.phase, .flying)
        XCTAssertEqual(restored.flight, original.flight)
        XCTAssertEqual(restored.trail, original.trail)
        XCTAssertEqual(restored.launches, original.launches)
        XCTAssertFalse(restored.isFastForwarding)
        original.setFastForwarding(false)
        for dt in [0.001, 0.0167, 0.003, 0.1] {
            original.tick(elapsed: dt); restored.tick(elapsed: dt)
            XCTAssertEqual(restored.flight, original.flight)
            XCTAssertEqual(restored.trail, original.trail)
        }
    }

    func testIgnoringLegacyHintDoesNotIgnoreChangedGameplayRules() throws {
        let level = LevelCatalog.all[0], session = GameSession(level: LevelCatalog.all[0])
        let checkpoint = try legacyCheckpoint(session)
        let changes: [(String, (inout Level) -> Void)] = [
            ("launch speed", { $0.ship.speed += 1 }),
            ("budget", { $0.matter += 1 }),
            ("dock radius", { $0.goal.r += 1 }),
            ("hole limit", { $0.limit = 1 })
        ]
        for (name, change) in changes {
            var changed = level; change(&changed)
            XCTAssertThrowsError(try GameSession(restoring: checkpoint, level: changed), name) {
                XCTAssertEqual($0 as? GameSession.CheckpointError, .levelMismatch, name)
            }
        }
    }

    func testRenamedSectorPreservesFlightAndUndoHistory() throws {
        let current = try XCTUnwrap(LevelCatalog.all.last)
        var legacy = current
        legacy.name = "Legacy final sector"
        let original = GameSession(level: legacy)
        original.showSolution()
        XCTAssertTrue(original.launch())
        original.tick(elapsed: 0.0173)
        let data = try JSONEncoder().encode(original.checkpoint())
        let checkpoint = try JSONDecoder().decode(GameSession.Checkpoint.self, from: data)
        let restored = try GameSession(restoring: checkpoint, level: current)
        XCTAssertEqual(restored.level.name, current.name)
        XCTAssertEqual(restored.holes, original.holes)
        XCTAssertEqual(restored.launches, original.launches)
        XCTAssertEqual(restored.flight, original.flight)
        XCTAssertEqual(restored.trail, original.trail)
        for dt in [0.001, 0.0167, 0.003, 0.1] {
            original.tick(elapsed: dt); restored.tick(elapsed: dt)
            XCTAssertEqual(restored.flight, original.flight)
            XCTAssertEqual(restored.trail, original.trail)
        }
        original.retry(); restored.retry()
        XCTAssertTrue(restored.canUndo)
        original.undo(); restored.undo()
        XCTAssertEqual(restored.holes, original.holes)
        XCTAssertEqual(restored.assisted, original.assisted)
    }

    func testEachRenamedCatalogCheckpointHasExactlyOneRuleMatch() {
        for (index, level) in LevelCatalog.all.enumerated() {
            var legacy = level
            legacy.name = "Previous title"
            let checkpoint = GameSession(level: legacy).checkpoint()
            let matches = LevelCatalog.all.indices.filter { checkpoint.matches(LevelCatalog.all[$0]) }
            XCTAssertEqual(matches, [index])
        }
    }

    func testRenameCannotHideChangedRulesOrAnActiveSectorCachedTrail() throws {
        let level = LevelCatalog.all[0]
        var legacy = level
        legacy.name = "Previous title"
        let checkpoint = GameSession(level: legacy).checkpoint()
        var changed = level
        changed.matter += 1
        XCTAssertFalse(checkpoint.matches(changed))
        XCTAssertThrowsError(try GameSession(restoring: checkpoint, level: changed)) {
            XCTAssertEqual($0 as? GameSession.CheckpointError, .levelMismatch)
        }
        let data = try JSONEncoder().encode(checkpoint)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        root["cachedTrailsByLevel"] = [legacy.name: [["x": 100, "y": 100]]]
        let corrupt = try JSONDecoder().decode(GameSession.Checkpoint.self,
            from: JSONSerialization.data(withJSONObject: root))
        XCTAssertThrowsError(try GameSession(restoring: corrupt, level: level)) {
            XCTAssertEqual($0 as? GameSession.CheckpointError, .invalidState)
        }
    }
}
