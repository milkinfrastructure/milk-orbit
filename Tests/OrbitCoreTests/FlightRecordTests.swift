import Foundation
import XCTest
@testable import OrbitCore

final class FlightRecordTests: XCTestCase {
    private func win(_ index: Int, fast: Bool = true) throws -> GameSession {
        let session = GameSession(level: LevelCatalog.all[index])
        session.showSolution(); XCTAssertTrue(session.launch()); session.setFastForwarding(fast)
        for _ in 0..<4000 where session.phase == .flying { session.tick(elapsed: 1.0/60) }
        XCTAssertEqual(session.flight?.status, .won)
        return session
    }
    func testOnlyFinishedWinningFlightProducesRecord() throws {
        let session = GameSession(level: LevelCatalog.all[0])
        XCTAssertNil(FlightRecord(session: session, sectorIndex: 0, sectorCount: 20))
        session.showSolution(); XCTAssertTrue(session.launch())
        XCTAssertNil(FlightRecord(session: session, sectorIndex: 0, sectorCount: 20))
        session.retry()
        XCTAssertNil(FlightRecord(session: session, sectorIndex: 0, sectorCount: 20))
    }
    func testImmutableAssistedSnapshotSurvivesRetryResetAndAnotherSector() throws {
        let session = try win(2)
        let record = try XCTUnwrap(FlightRecord(session: session, sectorIndex: 2, sectorCount: 20))
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(record.pull, session.holes.reduce(0) { $0 + $1.mass })
        XCTAssertEqual(record.holes, 1); XCTAssertTrue(record.assisted)
        XCTAssertEqual(record.launches, 1); XCTAssertFalse(record.isFinalSector)
        session.retry(); session.reset(); session.load(level: LevelCatalog.all[0])
        XCTAssertEqual(try JSONDecoder().decode(FlightRecord.self, from: data), record)
        XCTAssertEqual(record.sectorName, LevelCatalog.all[2].name)
        XCTAssertTrue(record.assisted); XCTAssertTrue(record.isValid)
    }
    func testRestoredWinAndPlaybackRateProduceSameFacts() throws {
        let slow = try win(0, fast: false), fast = try win(0)
        let checkpoint = try JSONDecoder().decode(GameSession.Checkpoint.self, from: JSONEncoder().encode(fast.checkpoint()))
        let restored = try GameSession(restoring: checkpoint, level: LevelCatalog.all[0])
        let expected = FlightRecord(session: slow, sectorIndex: 0, sectorCount: 20)
        XCTAssertEqual(expected, FlightRecord(session: fast, sectorIndex: 0, sectorCount: 20))
        XCTAssertEqual(expected, FlightRecord(session: restored, sectorIndex: 0, sectorCount: 20))
    }
    func testFinalSectorIsNotAnInventedCampaignAggregate() throws {
        let session = try win(19)
        let record = try XCTUnwrap(FlightRecord(session: session, sectorIndex: 19, sectorCount: 20))
        XCTAssertTrue(record.isFinalSector); XCTAssertEqual(record.launches, 1)
        session.retry(); XCTAssertTrue(session.launch()); session.setFastForwarding(true)
        for _ in 0..<4000 where session.phase == .flying { session.tick(elapsed: 1.0/60) }
        XCTAssertEqual(FlightRecord(session: session, sectorIndex: 19, sectorCount: 20)?.launches, 2)
        XCTAssertEqual(record.launches, 1)
        XCTAssertNil(FlightRecord(session: session, sectorIndex: 20, sectorCount: 20))
    }
    func testMalformedStoredFactsAreNotEligibleToPresentOrShare() throws {
        let record = try XCTUnwrap(FlightRecord(session: win(0), sectorIndex: 0, sectorCount: 20))
        let data = try JSONEncoder().encode(record)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value): (String, Any) in [("pull", -1.0), ("pull", 1e100), ("holes", 33), ("launches", 0), ("sectorIndex", 20)] {
            var edited = original; edited[key] = value
            let decoded = try JSONDecoder().decode(FlightRecord.self, from: JSONSerialization.data(withJSONObject: edited))
            XCTAssertFalse(decoded.isValid, key)
        }
    }
}
