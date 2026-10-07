import XCTest
@testable import OrbitCore

final class StrengthRepeatTests: XCTestCase {
    func testImmediateHalfStepDelayAndCadence() {
        let id = UUID()
        var state = StrengthRepeat()
        XCTAssertEqual(state.begin(holeID: id, direction: .increase, at: 10), 0.5)
        XCTAssertEqual(state.begin(holeID: id, direction: .increase, at: 10.1), 0)
        XCTAssertEqual(state.begin(holeID: UUID(), direction: .decrease, at: 10.1), 0)
        XCTAssertEqual(state.advance(at: 10.349, selectedHoleID: id, editable: true), 0)
        XCTAssertEqual(state.advance(at: 10.35, selectedHoleID: id, editable: true), 0.5)
        XCTAssertEqual(state.advance(at: 10.449, selectedHoleID: id, editable: true), 0)
        XCTAssertEqual(state.advance(at: 10.45, selectedHoleID: id, editable: true), 0.5)
        state.cancel()
        XCTAssertEqual(state.begin(holeID: id, direction: .decrease, at: 20), -0.5)
        XCTAssertEqual(state.advance(at: 20.35, selectedHoleID: id, editable: true), -0.5)
    }

    func testLateAndDuplicateCallbacksDoNotBurst() {
        let id = UUID()
        var state = StrengthRepeat()
        XCTAssertEqual(state.begin(holeID: id, direction: .increase, at: 0), 0.5)
        XCTAssertEqual(state.advance(at: 20, selectedHoleID: id, editable: true), 0.5)
        for _ in 0..<10 { XCTAssertEqual(state.advance(at: 20, selectedHoleID: id, editable: true), 0) }
        XCTAssertEqual(state.advance(at: 20.099, selectedHoleID: id, editable: true), 0)
        XCTAssertEqual(state.advance(at: 20.1, selectedHoleID: id, editable: true), 0.5)
    }

    func testCancelTargetChangeAndIneligibleStateStopRepeating() {
        let id = UUID()
        var state = StrengthRepeat()
        XCTAssertEqual(state.begin(holeID: id, direction: .increase, at: 0), 0.5)
        state.cancel() // Release/outside/system/lifecycle routes share this operation.
        XCTAssertFalse(state.isActive)
        XCTAssertEqual(state.advance(at: 10, selectedHoleID: id, editable: true), 0)
        XCTAssertEqual(state.begin(holeID: id, direction: .increase, at: 10), 0.5)
        XCTAssertEqual(state.advance(at: 10.1, selectedHoleID: id, editable: true), 0,
                       "A new press must wait the initial delay again")
        state.cancel()
        for selection in [Optional<UUID>.none, Optional(UUID())] {
            XCTAssertEqual(state.begin(holeID: id, direction: .increase, at: 1), 0.5)
            XCTAssertEqual(state.advance(at: 1.4, selectedHoleID: selection, editable: true), 0)
            XCTAssertFalse(state.isActive)
        }
        XCTAssertEqual(state.begin(holeID: id, direction: .increase, at: 1), 0.5)
        XCTAssertEqual(state.advance(at: 1.4, selectedHoleID: id, editable: false), 0)
        XCTAssertFalse(state.isActive)
    }

    func testInvalidAndBackwardClocksStopRepeating() {
        let id = UUID()
        var state = StrengthRepeat()
        for invalid in [Double.nan, .infinity, -.infinity, -1, .greatestFiniteMagnitude] {
            XCTAssertEqual(state.begin(holeID: id, direction: .increase, at: invalid), 0)
            XCTAssertFalse(state.isActive)
            XCTAssertEqual(state.begin(holeID: id, direction: .increase, at: 1), 0.5)
            XCTAssertEqual(state.advance(at: invalid, selectedHoleID: id, editable: true), 0)
            XCTAssertFalse(state.isActive)
        }
        XCTAssertEqual(state.begin(holeID: id, direction: .increase, at: 3), 0.5)
        XCTAssertEqual(state.advance(at: 2, selectedHoleID: id, editable: true), 0)
        XCTAssertFalse(state.isActive)
    }

    func testCoreClampStopsRepeatWithoutExtraClick() {
        let level = Level(name: "Repeat", matter: 8, ship: Ship(x: 100, y: 450, speed: 150),
                          goal: Goal(x: 1500, y: 450, r: 24))
        for direction in [StrengthDirection.increase, .decrease] {
            let session = GameSession(level: level)
            XCTAssertTrue(session.begin(at: Vec2(x: 800, y: 450), screenY: 0, hitRadius: 0))
            session.end()
            if direction == .decrease { session.adjustSelected(by: 6) }
            let id = session.holes[0].id
            var feedback = StrengthChangeFeedback(), state = StrengthRepeat(), clicks = 0
            feedback.reset(to: session.holes[0].mass)
            var delta = state.begin(holeID: id, direction: direction, at: 0)
            for index in 0..<20 {
                let before = session.holes[0].mass
                session.adjustSelected(by: delta)
                let after = session.holes[0].mass
                state.didApply(before: before, after: after)
                if feedback.changed(to: after) { clicks += 1 }
                XCTAssertTrue((2...8).contains(after))
                XCTAssertEqual(after * 2, (after * 2).rounded())
                delta = state.advance(at: 0.35 + Double(index) * 0.1,
                                      selectedHoleID: session.selectedID, editable: session.phase == .setup)
            }
            XCTAssertEqual(session.holes[0].mass, direction == .increase ? 8 : 2)
            XCTAssertEqual(clicks, 12)
            XCTAssertFalse(state.isActive)
        }
        var invalid = StrengthRepeat()
        _ = invalid.begin(holeID: UUID(), direction: .increase, at: 0)
        invalid.didApply(before: 4, after: .nan)
        XCTAssertFalse(invalid.isActive)
    }

    func testCommittedHalfStepFeedbackAndReset() {
        var feedback = StrengthChangeFeedback()
        feedback.reset(to: 2)
        XCTAssertFalse(feedback.changed(to: 2))
        XCTAssertTrue(feedback.changed(to: 2.5))
        XCTAssertFalse(feedback.changed(to: 2.5 + 1e-12))
        XCTAssertTrue(feedback.changed(to: 3))
        XCTAssertTrue(feedback.changed(to: 2.5), "A real reversed half-step also clicks")
        XCTAssertTrue(feedback.changed(to: 6))
        XCTAssertFalse(feedback.changed(to: 6))
        feedback.reset(to: 12)
        XCTAssertFalse(feedback.changed(to: 12), "A new selection only seeds the baseline")
        XCTAssertTrue(feedback.changed(to: 12.5))
        for invalid in [Double.nan, .infinity, -.infinity, -1, 2.25, 2.3, .greatestFiniteMagnitude] {
            XCTAssertFalse(feedback.changed(to: invalid))
            XCTAssertFalse(feedback.changed(to: 2), "Invalid input clears a stale baseline")
        }
        feedback.reset()
        XCTAssertFalse(feedback.changed(to: 2))
    }
}
