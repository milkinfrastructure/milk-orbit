import XCTest
@testable import OrbitCore

final class CheckpointTests: XCTestCase {
    private func fixture(limit: Int? = nil) -> Level {
        Level(name: "Checkpoint fixture", matter: 80,
              ship: Ship(x: 100, y: 450, speed: 150),
              goal: Goal(x: 1500, y: 450, r: 24), limit: limit)
    }
    private func roundTrip(_ session: GameSession, level: Level? = nil) throws -> GameSession {
        let data = try JSONEncoder().encode(session.checkpoint())
        let value = try JSONDecoder().decode(GameSession.Checkpoint.self, from: data)
        XCTAssertEqual(value.version, 1)
        XCTAssertEqual(value.levelName, session.level.name)
        return try GameSession(restoring: value, level: level ?? session.level)
    }
    private func place(_ session: GameSession, at point: Vec2 = Vec2(x: 800, y: 100)) {
        XCTAssertTrue(session.begin(at: point, screenY: 0, hitRadius: 0))
        session.end()
    }
    private func assertStateEqual(_ a: GameSession, _ b: GameSession, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.holes, b.holes, file: file, line: line)
        XCTAssertEqual(a.phase, b.phase, file: file, line: line)
        XCTAssertEqual(a.flight, b.flight, file: file, line: line)
        XCTAssertEqual(a.trail, b.trail, file: file, line: line)
        XCTAssertEqual(a.ghost, b.ghost, file: file, line: line)
        XCTAssertEqual(a.lastCompletedTrail, b.lastCompletedTrail, file: file, line: line)
        XCTAssertEqual(a.launches, b.launches, file: file, line: line)
        XCTAssertEqual(a.assisted, b.assisted, file: file, line: line)
        XCTAssertEqual(a.canUndo, b.canUndo, file: file, line: line)
    }

    func testSetupRoundTripPreservesOffGridPlacementHalfStepsAndUndoOrder() throws {
        let original = GameSession(level: fixture())
        place(original, at: Vec2(x: 817, y: 113))
        original.adjustSelected(by: 0.5)
        let resized = original.holes
        XCTAssertTrue(original.begin(at: resized[0].position, screenY: 0, hitRadius: 0))
        original.move(to: Vec2(x: 941, y: 171))
        original.end()
        let restored = try roundTrip(original)
        assertStateEqual(original, restored)
        XCTAssertEqual(restored.selectedID, original.selectedID)
        XCTAssertEqual(restored.holes[0].position, Vec2(x: 960, y: 160))
        for _ in 0..<3 {
            original.undo(); restored.undo()
            assertStateEqual(original, restored)
        }
        XCTAssertTrue(restored.holes.isEmpty)
    }

    func testInterruptedDragIsCommittedOnceOnlyInSavedValue() throws {
        for newHole in [true, false] {
            let original = GameSession(level: fixture())
            if !newHole { place(original) }
            let before = original.holes
            XCTAssertTrue(original.begin(at: Vec2(x: 800, y: 100), screenY: 0, hitRadius: 0))
            original.dragPrecisely(screenY: -50 * log(2.5 / 2))
            let edited = original.holes
            let restored = try roundTrip(original)
            XCTAssertTrue(original.isInteracting, "Export does not mutate the live gesture")
            XCTAssertFalse(restored.isInteracting)
            XCTAssertFalse(restored.isFastForwarding)
            XCTAssertEqual(restored.holes, edited)
            restored.undo()
            XCTAssertEqual(restored.holes, before, "Interrupted edit remains one undo")
            original.cancel()
            XCTAssertEqual(original.holes, before, "Existing cancellation semantics remain unchanged")
        }
    }

    func testHeldFourTimesRestoreKeepsFractionalAccumulatorAndResumesAtOneTimes() throws {
        let original = GameSession(level: fixture())
        XCTAssertTrue(original.launch())
        original.setFastForwarding(true)
        original.tick(elapsed: 0.0017) // One 1/240 step plus a nonzero remainder at 4×.
        let restored = try roundTrip(original)
        XCTAssertTrue(original.isFastForwarding)
        XCTAssertFalse(restored.isFastForwarding)
        XCTAssertFalse(restored.isInteracting)
        assertStateEqual(original, restored)
        original.setFastForwarding(false)
        for dt in [0.001, 0.003, 0.013, 0.0167, 0.001] {
            original.tick(elapsed: dt); restored.tick(elapsed: dt)
            assertStateEqual(original, restored)
        }
    }

    func testAllCatalogSolutionsAndFlightsRoundTripWithoutQuantizingOriginalMasses() throws {
        for level in LevelCatalog.all {
            let original = GameSession(level: level)
            original.showSolution()
            let setup = try roundTrip(original)
            XCTAssertEqual(setup.holes, level.answer, level.name)
            XCTAssertEqual(setup.assisted, true)
            let launched = original.launch()
            XCTAssertTrue(launched, level.name)
            guard launched else { continue }
            // Launch has an infinite closest-distance sentinel; default JSON must still round-trip.
            assertStateEqual(original, try roundTrip(original))
            original.tick(elapsed: 0.0123)
            let restored = try roundTrip(original)
            for _ in 0..<460 where original.phase == .flying {
                original.tick(elapsed: 0.1); restored.tick(elapsed: 0.1)
                XCTAssertEqual(original.flight, restored.flight, level.name)
                XCTAssertEqual(original.trail, restored.trail, level.name)
            }
            XCTAssertEqual(original.phase, .finished, level.name)
            assertStateEqual(original, try roundTrip(original))
            original.retry()
            let afterRetry = try roundTrip(original)
            assertStateEqual(original, afterRetry)
            original.undo(); afterRetry.undo()
            assertStateEqual(original, afterRetry)
        }
    }

    func testPortalCooldownAndBreakSurviveRestore() throws {
        var level = fixture()
        level.bodies = [Body(type: .wormhole, x: 100, y: 450, r: 30, id: "a", twin: "b"),
                        Body(type: .wormhole, x: 800, y: 450, r: 30, id: "b", twin: "a")]
        let original = GameSession(level: level)
        XCTAssertTrue(original.launch())
        original.tick(elapsed: Physics.stepDuration)
        XCTAssertEqual(original.flight?.portal, "b")
        XCTAssertNotNil(original.flight?.jumped)
        XCTAssertTrue(original.trail.contains(nil))
        let restored = try roundTrip(original)
        assertStateEqual(original, restored)
        for _ in 0..<10 {
            original.tick(elapsed: 0.01); restored.tick(elapsed: 0.01)
            assertStateEqual(original, restored)
        }
    }

    func testUndoHistoryRemainsBoundedAndCompletedTrailSurvives() throws {
        let original = GameSession(level: fixture())
        XCTAssertTrue(original.launch())
        for _ in 0..<460 where original.phase == .flying { original.tick(elapsed: 0.1) }
        original.retry()
        place(original)
        for i in 0..<80 { original.adjustSelected(by: i.isMultiple(of: 2) ? 0.5 : -0.5) }
        let restored = try roundTrip(original)
        let completed = original.lastCompletedTrail
        var count = 0
        while restored.canUndo {
            original.undo(); restored.undo(); count += 1
            assertStateEqual(original, restored)
        }
        XCTAssertEqual(count, 64)
        XCTAssertEqual(restored.lastCompletedTrail, completed)
        restored.reset()
        XCTAssertEqual(restored.lastCompletedTrail, completed, "Reset preserves the completed reference trail")
    }

    func testThirtyTwoHoleLayoutAndBudgetRoundTrip() throws {
        let original = GameSession(level: fixture())
        for row in 0..<4 {
            for column in 0..<8 {
                place(original, at: Vec2(x: 300 + Double(column) * 130, y: 150 + Double(row) * 200))
            }
        }
        let restored = try roundTrip(original)
        XCTAssertEqual(restored.holes.count, 32)
        XCTAssertEqual(restored.remainingHoleSlots, 0)
        XCTAssertEqual(restored.availableMatter, 16)
        assertStateEqual(original, restored)
        restored.adjustSelected(by: 0.5)
        XCTAssertEqual(restored.holes.last?.mass, 2.5)
        XCTAssertEqual(restored.availableMatter, 15.5)
    }

    func testRejectsWrongVersionLevelBudgetGeometryAndMalformedHistory() throws {
        let original = GameSession(level: fixture(limit: 1))
        place(original)
        let encoded = try JSONEncoder().encode(original.checkpoint())
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("version", { $0["version"] = 999 }),
            ("budget", { root in var holes = root["holes"] as! [[String: Any]]; holes[0]["mass"] = 80.5; root["holes"] = holes }),
            ("quarter strength", { root in var holes = root["holes"] as! [[String: Any]]; holes[0]["mass"] = 2.25; root["holes"] = holes }),
            ("nonfinite", { root in var holes = root["holes"] as! [[String: Any]]; holes[0]["x"] = "NaN"; root["holes"] = holes }),
            ("outside", { root in var holes = root["holes"] as! [[String: Any]]; holes[0]["x"] = -1; root["holes"] = holes }),
            ("ship clearance", { root in var holes = root["holes"] as! [[String: Any]]; holes[0]["x"] = 100; holes[0]["y"] = 450; root["holes"] = holes }),
            ("hole limit", { root in let holes = root["holes"] as! [[String: Any]]; var extra = holes[0]; extra["id"] = UUID().uuidString; extra["x"] = 1100; root["holes"] = holes + [extra] }),
            ("duplicate identity", { root in let holes = root["holes"] as! [[String: Any]]; root["holes"] = holes + holes }),
            ("invalid selected ID", { $0["selectedID"] = UUID().uuidString }),
            ("excess history", { root in root["history"] = Array(repeating: (root["history"] as! [[String: Any]])[0], count: 65) }),
            ("invalid undo holes", { root in var history = root["history"] as! [[String: Any]]; history[0]["holes"] = root["holes"]; history[0]["selectedID"] = UUID().uuidString; root["history"] = history }),
            ("excess completed trail", { $0["lastCompletedTrail"] = Array(repeating: ["x": 1, "y": 1], count: 4097) }),
            ("setup accumulator", { $0["accumulatedTime"] = 0.001 })
        ]
        for (name, mutate) in mutations {
            var changed = base; mutate(&changed)
            let data = try JSONSerialization.data(withJSONObject: changed)
            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
            let checkpoint = try decoder.decode(GameSession.Checkpoint.self, from: data)
            XCTAssertThrowsError(try GameSession(restoring: checkpoint, level: original.level), name)
        }
        var changedLevel = original.level
        changedLevel.ship.speed += 1
        XCTAssertThrowsError(try GameSession(restoring: original.checkpoint(), level: changedLevel))
        XCTAssertEqual(original.holes.count, 1, "Validation never mutates the original session")
    }

    func testRejectsInvalidFlightAndKeepsRegeneratedCatalogAnswerIDsCompatible() throws {
        let original = GameSession(level: LevelCatalog.all[0])
        original.showSolution(); XCTAssertTrue(original.launch()); original.tick(elapsed: 0.01)
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original.checkpoint())) as? [String: Any])
        for (key, value) in [("vx", 1e308 as Any), ("time", -1 as Any), ("left", 1 as Any),
                             ("passed", [true] as Any), ("portal", "unknown" as Any)] {
            var changed = base
            var flight = changed["flight"] as! [String: Any]
            flight[key] = value; changed["flight"] = flight
            let checkpoint = try JSONDecoder().decode(GameSession.Checkpoint.self, from: JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try GameSession(restoring: checkpoint, level: original.level), key)
        }
        var redecodedCatalogLevel = original.level
        redecodedCatalogLevel.answer = original.level.answer.map { Hole(x: $0.x, y: $0.y, mass: $0.mass) }
        assertStateEqual(original, try roundTrip(original, level: redecodedCatalogLevel))
    }
}
