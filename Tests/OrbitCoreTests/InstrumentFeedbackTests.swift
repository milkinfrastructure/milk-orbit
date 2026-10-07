import XCTest
@testable import OrbitCore

final class InstrumentFeedbackTests: XCTestCase {
    func testResultPreemptsInputAndDoesNotQueueOldSuccess() {
        var state = InstrumentFeedback()
        XCTAssertTrue(state.post("GATE CLEAR",announcement:"Gate clear",lamp:.green,priority:30,now:1))
        XCTAssertTrue(state.post("CAPTURED",announcement:"Black hole captured ship",lamp:.red,priority:90,now:1.1))
        XCTAssertFalse(state.post("PLACED",announcement:"Placed",lamp:.green,priority:10,now:1.2))
        XCTAssertEqual(state.visible(at:1.2)?.text,"CAPTURED")
        XCTAssertEqual(state.lamp(at:1.2),.red)
        XCTAssertEqual(state.lamp(at:1.8),.off)
        XCTAssertNotNil(state.visible(at:1.8))
        XCTAssertNil(state.visible(at:4))
        XCTAssertNil(state.nextDeadline(after:4))
    }
    func testResetAndNewLaunchCannotResurrectOldMessageOrLamp() {
        var state = InstrumentFeedback()
        state.post("IMPACT",announcement:"Impact",lamp:.red,priority:90,now:1)
        state.clear()
        XCTAssertNil(state.visible(at:1.1)); XCTAssertEqual(state.lamp(at:1.1),.off)
        XCTAssertTrue(state.post("LAUNCHED",announcement:"Ship launched",lamp:.green,priority:30,now:1.1))
        XCTAssertEqual(state.visible(at:1.2)?.text,"LAUNCHED")
        XCTAssertEqual(state.nextDeadline(after:1.1)!,1.75,accuracy:0.0001)
        XCTAssertEqual(state.nextDeadline(after:1.8)!,3.5,accuracy:0.0001)
    }
    func testRapidSamePriorityInputReplacesRatherThanBacklogs() {
        var state = InstrumentFeedback()
        for n in 0..<100 {
            state.post("INPUT \(n)",announcement:"Input",lamp:.red,priority:50,now:Double(n)/100)
        }
        XCTAssertEqual(state.visible(at:1)?.text,"INPUT 99")
        XCTAssertNil(state.visible(at:4))
        XCTAssertFalse(state.post("BAD",announcement:"Bad",lamp:.red,priority:99,now:.nan))
    }
}
