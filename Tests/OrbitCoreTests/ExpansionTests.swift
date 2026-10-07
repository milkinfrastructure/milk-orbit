import XCTest
@testable import OrbitCore

final class ExpansionTests: XCTestCase {
    private func fixture(matter: Double = 200, limit: Int? = nil) -> Level {
        Level(name: "Dense layout", matter: matter, ship: Ship(x: 100, y: 450, speed: 150),
              goal: Goal(x: 1500, y: 450, r: 24), limit: limit)
    }
    private func fill(_ session: GameSession, count: Int) {
        for y in stride(from: 100.0, through: 800, by: 100) {
            for x in stride(from: 200.0, through: 1400, by: 150) where session.holes.count < count {
                if session.begin(at: Vec2(x: x, y: y), screenY: 0, hitRadius: 0) { session.end() }
            }
        }
        XCTAssertEqual(session.holes.count, count)
    }
    func testMoreHolesRespectBudgetGlobalCeilingAndSpecialSectors() {
        let budget = GameSession(level: LevelCatalog.all[0])
        fill(budget, count: 20)
        XCTAssertEqual(budget.availableMatter, 0)
        XCTAssertFalse(budget.begin(at: Vec2(x: 1200, y: 750), screenY: 0, hitRadius: 0))
        XCTAssertTrue(budget.lastFeedback!.contains("strength"))
        let dense = GameSession(level: fixture())
        fill(dense, count: 32)
        XCTAssertFalse(dense.begin(at: Vec2(x: 1400, y: 800), screenY: 0, hitRadius: 0))
        XCTAssertTrue(dense.lastFeedback!.contains("32-hole"))
        dense.undo()
        XCTAssertNil(dense.lastFeedback)
        XCTAssertEqual(dense.remainingHoleSlots, 1)
        for index in [16, 19] {
            let session = GameSession(level: LevelCatalog.all[index])
            fill(session, count: session.holeLimit)
            XCTAssertFalse(session.begin(at: Vec2(x: 1400, y: 850), screenY: 0, hitRadius: 0))
            XCTAssertTrue(session.lastFeedback!.contains("sector allows"))
        }
    }
    func testPreciseStrengthReanchorsAndUsesReversibleHalfSteps() {
        let s = GameSession(level: fixture())
        XCTAssertTrue(s.begin(at: Vec2(x: 800, y: 450), screenY: 100, hitRadius: 0))
        s.reanchorStrength(screenY: 90)
        s.dragPrecisely(screenY: 90)
        XCTAssertEqual(s.holes[0].mass, 2)
        s.dragPrecisely(screenY: 89)
        XCTAssertEqual(s.holes[0].mass, 2, "Small motion below a half-step boundary has no effect")
        s.dragPrecisely(screenY: 84)
        XCTAssertEqual(s.holes[0].mass, 2.5)
        s.dragPrecisely(screenY: 90)
        XCTAssertEqual(s.holes[0].mass, 2)
        s.end(); s.adjustSelected(by: 0.5)
        XCTAssertEqual(s.holes[0].mass, 2.5)
        s.adjustSelected(by: -0.5)
        XCTAssertEqual(s.holes[0].mass, 2)
        XCTAssertTrue(s.begin(at: s.holes[0].position, screenY: 0, hitRadius: 0))
        s.dragPrecisely(screenY: -Double.greatestFiniteMagnitude)
        XCTAssertTrue(s.holes[0].mass.isFinite)
        XCTAssertLessThanOrEqual(s.holes[0].mass, s.level.matter)
        s.cancel(); XCTAssertEqual(s.holes[0].mass, 2)
    }
    func testAllEdgesAndCornersClampWithoutChangingStrengthAndUndo() {
        let s = GameSession(level: fixture())
        XCTAssertTrue(s.begin(at: Vec2(x: 800, y: 450), screenY: 0, hitRadius: 0)); s.end()
        let original = s.holes[0]
        let edge = Physics.horizonRadius(mass: 2) + Physics.clearance
        let cases: [(Vec2, Vec2)] = [
            (Vec2(x: -200, y: -200), Vec2(x: edge, y: edge)),
            (Vec2(x: 1800, y: -200), Vec2(x: 1600-edge, y: edge)),
            (Vec2(x: -200, y: 1100), Vec2(x: edge, y: 900-edge)),
            (Vec2(x: 1800, y: 1100), Vec2(x: 1600-edge, y: 900-edge)),
            (Vec2(x: -200, y: 450), Vec2(x: edge, y: 440)),
            (Vec2(x: 1800, y: 450), Vec2(x: 1600-edge, y: 440)),
            (Vec2(x: 800, y: -200), Vec2(x: 800, y: edge)),
            (Vec2(x: 800, y: 1100), Vec2(x: 800, y: 900-edge))
        ]
        for (p, expected) in cases {
            XCTAssertTrue(s.begin(at: s.holes[0].position, screenY: 0, hitRadius: 0))
            s.move(to: p); s.end()
            XCTAssertEqual(s.holes[0].x, expected.x, accuracy: 1e-9)
            XCTAssertEqual(s.holes[0].y, expected.y, accuracy: 1e-9)
            XCTAssertEqual(s.holes[0].mass, 2)
            s.undo(); XCTAssertEqual(s.holes[0], original)
        }
    }
    func testMappingHasNoDeadBandsAndHitTestingUsesScreenDistance() {
        for size in [(402.0, 774.0), (754.0, 381.0), (1000.0, 300.0)] {
            let t = BoardTransform(width: size.0, height: size.1)
            for x in [0.0, size.0 / 2, size.0] {
                for y in [0.0, size.1 / 2, size.1] {
                    let p = Vec2(x: x, y: y), world = t.worldPoint(p), roundtrip = t.screenPoint(world)
                    XCTAssertEqual(roundtrip.x, p.x, accuracy: 1e-9)
                    XCTAssertEqual(roundtrip.y, p.y, accuracy: 1e-9)
                    XCTAssertTrue((0...1600).contains(world.x)); XCTAssertTrue((0...900).contains(world.y))
                }
            }
            let h = Hole(x: 800, y: 450, mass: 2), center = t.screenPoint(Vec2(x: 800, y: 450))
            XCTAssertNil(t.hitHole(in: [h], at: center + Vec2(x: 40, y: 0)))
            XCTAssertEqual(t.hitHole(in: [h], at: center + Vec2(x: 29, y: 0)), h)
        }
    }
    func testEmptyTapDismissalConsumesOnlyFirstTapAndKeepsUndo() {
        let s = GameSession(level: fixture())
        XCTAssertTrue(s.begin(at: Vec2(x: 800, y: 450), screenY: 0, hitRadius: 0)); s.end()
        let before = s.holes
        XCTAssertFalse(s.dismissIfEmpty(hitHole: before[0]))
        XCTAssertTrue(s.dismissIfEmpty(hitHole: nil))
        XCTAssertEqual(s.holes, before); XCTAssertNil(s.selectedID)
        XCTAssertFalse(s.dismissIfEmpty(hitHole: nil))
        XCTAssertTrue(s.begin(at: Vec2(x: 1100, y: 650), screenY: 0, hitRadius: 0)); s.end()
        XCTAssertEqual(s.holes.count, 2)
        s.undo(); XCTAssertEqual(s.holes, before)
        for _ in 0..<100 { XCTAssertTrue(s.dismissIfEmpty(hitHole: nil, additionalOverlay: true)) }
        XCTAssertEqual(s.holes, before)
        s.undo(); XCTAssertTrue(s.holes.isEmpty)
    }
    func testDenseFlightsKeepFixedStepEquivalenceAndBoundedHistory() {
        for count in [0, 8, 16, 32] {
            let normal = GameSession(level: fixture()), fast = GameSession(level: fixture())
            fill(normal, count: count); fill(fast, count: count)
            XCTAssertTrue(normal.launch()); XCTAssertTrue(fast.launch()); fast.setFastForwarding(true)
            for _ in 0..<1500 where normal.phase == .flying {
                for _ in 0..<4 { normal.tick(elapsed: 1.0/60) }; fast.tick(elapsed: 1.0/60)
                XCTAssertEqual(normal.flight?.position, fast.flight?.position)
                XCTAssertEqual(normal.flight?.status, fast.flight?.status)
                XCTAssertTrue(normal.flight!.x.isFinite && normal.flight!.y.isFinite)
            }
            XCTAssertEqual(normal.phase, .finished)
        }
        let s = GameSession(level: LevelCatalog.all[0])
        for _ in 0..<100 { s.showSolution() }
        var undos = 0
        while s.canUndo { s.undo(); undos += 1 }
        XCTAssertEqual(undos, 64)
    }
}
