import XCTest
@testable import OrbitCore

final class TrailPolicyTests: XCTestCase {
    private func fixture(_ index: Int = 0) -> Level {
        Level(name: "Trail sector \(index)", matter: 80,
              ship: Ship(x: 100, y: 200 + Double(index) * 20, speed: 10_000),
              goal: Goal(x: 1500, y: 850, r: 10))
    }
    private func finish(_ session: GameSession) {
        XCTAssertTrue(session.launch())
        for _ in 0..<500 where session.phase == .flying { session.tick(elapsed: 0.1) }
        XCTAssertEqual(session.phase, .finished)
        XCTAssertFalse(session.lastCompletedTrail.isEmpty)
    }
    private func encodedObject(_ session: GameSession) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session.checkpoint())) as? [String: Any])
    }
    private func restored(_ object: [String: Any], level: Level) throws -> GameSession {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let checkpoint = try decoder.decode(GameSession.Checkpoint.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(checkpoint.version, 1)
        return try GameSession(restoring: checkpoint, level: level)
    }

    func testFailedTrailSurvivesResetAndRejectedBecalmedLaunch() throws {
        var level = fixture()
        level.ship = Ship(x: 100, y: 450, speed: 0)
        let session = GameSession(level: level)
        XCTAssertTrue(session.begin(at: Vec2(x: 200, y: 450), screenY: 0, hitRadius: 0))
        session.end()
        finish(session)
        XCTAssertNotEqual(session.flight?.status, .won)
        let completed = session.lastCompletedTrail
        XCTAssertFalse(session.launch(), "Finished phase is not an accepted new launch")
        XCTAssertEqual(session.lastCompletedTrail, completed)
        session.retry()
        session.reset()
        XCTAssertTrue(session.holes.isEmpty)
        XCTAssertEqual(session.lastCompletedTrail, completed)
        XCTAssertFalse(session.launch(), "No initial velocity or remaining attraction")
        XCTAssertEqual(session.lastCompletedTrail, completed)
        XCTAssertEqual(session.phase, .setup)
        let resumed = try restored(encodedObject(session), level: level)
        XCTAssertEqual(resumed.lastCompletedTrail, completed)
        resumed.clearSelection()
        resumed.undo()
        XCTAssertEqual(resumed.lastCompletedTrail, completed)
        XCTAssertTrue(resumed.launch())
        XCTAssertTrue(resumed.lastCompletedTrail.isEmpty)
    }

    func testAllTwentySectorTrailsSurviveSwitchAndCheckpoint() throws {
        let levels = (0..<20).map(fixture)
        let session = GameSession(level: levels[0])
        var expected: [String: [Vec2?]] = [:]
        for level in levels {
            session.load(level: level)
            finish(session)
            XCTAssertEqual(session.flight?.status, .lost)
            expected[level.name] = session.lastCompletedTrail
            session.retry()
        }
        let payload = try encodedObject(session)
        let cached = try XCTUnwrap(payload["cachedTrailsByLevel"] as? [String: Any])
        XCTAssertEqual(cached.count, 19, "Current trail occupies the legacy field; no duplicate cache entry")
        XCTAssertNil(cached[session.level.name])
        let resumed = try restored(payload, level: session.level)
        for level in levels {
            resumed.load(level: level)
            XCTAssertEqual(resumed.lastCompletedTrail, expected[level.name]!)
            XCTAssertLessThanOrEqual(resumed.lastCompletedTrail.count, 4096)
        }
        resumed.load(level: levels[0])
        XCTAssertTrue(resumed.launch())
        XCTAssertTrue(resumed.lastCompletedTrail.isEmpty)
        resumed.retry()
        resumed.load(level: levels[1])
        XCTAssertEqual(resumed.lastCompletedTrail, expected[levels[1].name]!)
        resumed.load(level: levels[0])
        XCTAssertTrue(resumed.lastCompletedTrail.isEmpty, "Accepted launch invalidates only that sector's previous trail")
    }

    func testRenamedCatalogOverlayCannotEvictAnotherSectorsTrail() throws {
        let current = (0..<20).map(fixture)
        var legacy = current
        legacy[19].name = "ZZ legacy final sector"
        let session = GameSession(level: legacy[0])
        var expected: [String: [Vec2?]] = [:]
        for level in legacy {
            session.load(level: level)
            finish(session)
            expected[level.name] = session.lastCompletedTrail
            session.retry()
        }
        session.load(level: legacy[0])
        let payload = try encodedObject(session)
        let resumed = try restored(payload, level: current[0])
        let activeTrail = resumed.lastCompletedTrail
        XCTAssertTrue(resumed.pruneCachedTrails(keeping: Set(current.map(\.name))))
        XCTAssertFalse(resumed.pruneCachedTrails(keeping: Set(current.map(\.name))))
        XCTAssertEqual(resumed.lastCompletedTrail, activeTrail)
        XCTAssertEqual(resumed.holes, session.holes)
        XCTAssertEqual(resumed.phase, session.phase)
        XCTAssertEqual(resumed.flight, session.flight)
        XCTAssertEqual(resumed.canUndo, session.canUndo)
        resumed.load(level: current[19])
        XCTAssertTrue(resumed.lastCompletedTrail.isEmpty)
        for level in current.dropLast() {
            resumed.load(level: level)
            XCTAssertEqual(resumed.lastCompletedTrail, expected[level.name]!)
        }
        let originalCache = try XCTUnwrap(payload["cachedTrailsByLevel"] as? [String: Any])
        XCTAssertNotNil(originalCache[legacy[19].name], "The original payload remains available for recovery")
    }

    func testLegacyVersionOneMissingCacheKeepsCurrentTrail() throws {
        let level = fixture()
        let session = GameSession(level: level)
        finish(session)
        session.retry()
        let expected = session.lastCompletedTrail
        var payload = try encodedObject(session)
        payload.removeValue(forKey: "cachedTrailsByLevel")
        let resumed = try restored(payload, level: level)
        XCTAssertEqual(resumed.lastCompletedTrail, expected)
        resumed.load(level: fixture(1))
        XCTAssertTrue(resumed.lastCompletedTrail.isEmpty)
        resumed.load(level: level)
        XCTAssertEqual(resumed.lastCompletedTrail, expected)
    }

    func testLegacyInFlightCheckpointDoesNotResurrectPrelaunchTrail() throws {
        let level = fixture()
        let session = GameSession(level: level)
        finish(session)
        let completed = session.lastCompletedTrail
        session.retry()
        XCTAssertTrue(session.launch())
        var payload = try encodedObject(session)
        payload.removeValue(forKey: "cachedTrailsByLevel")
        payload["lastCompletedTrail"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(completed))
        let resumed = try restored(payload, level: level)
        XCTAssertEqual(resumed.phase, .flying)
        XCTAssertTrue(resumed.lastCompletedTrail.isEmpty)
        XCTAssertEqual(resumed.flight, session.flight)
        XCTAssertEqual(resumed.trail, session.trail)
        XCTAssertFalse(resumed.isFastForwarding)
    }

    func testRejectsOversizedDuplicateAndNonfiniteTrailCaches() throws {
        let level = fixture()
        let session = GameSession(level: level)
        let base = try encodedObject(session)
        let point: [String: Any] = ["x": 1.0, "y": 2.0]
        let nonfinitePoint: [String: Any] = ["x": "NaN", "y": 2.0]
        let cases: [[String: Any]] = [
            Dictionary(uniqueKeysWithValues: (0..<20).map { ("Other \($0)", [point] as Any) }),
            [level.name: [point]],
            ["Other": Array(repeating: point, count: 4097)],
            ["Other": [nonfinitePoint]],
            ["Other": [["x": 1_000_001.0, "y": 2.0]]]
        ]
        for cached in cases {
            var changed = base
            changed["cachedTrailsByLevel"] = cached
            XCTAssertThrowsError(try restored(changed, level: level))
        }
    }
}
