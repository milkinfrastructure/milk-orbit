import XCTest
@testable import OrbitCore

final class FlightHapticMapperTests: XCTestCase {
    private func source(_ id: String = "a", x: Double, y: Double = 0, mass: Double = 8,
                        player: Bool = true) -> FlightHapticAttractor {
        FlightHapticAttractor(id: id, position: Vec2(x: x, y: y), mass: mass,
                             radius: 14, isPlayerHole: player)
    }

    private func step(_ mapper: inout FlightHapticMapper, sources: [FlightHapticAttractor],
                      dt: Double = 1.0 / 60, active: Bool = true,
                      position: Vec2 = .zero, velocity: Vec2 = Vec2(x: 150, y: 0),
                      acceleration: Vec2 = .zero) -> FlightHapticSample {
        mapper.update(active: active, position: position, velocity: velocity,
                      acceleration: acceleration, attractors: sources, elapsed: dt)
    }

    private func settled(_ sources: [FlightHapticAttractor], hz: Int = 60,
                         velocity: Vec2 = Vec2(x: 150, y: 0),
                         acceleration: Vec2 = .zero) -> FlightHapticSample {
        var mapper = FlightHapticMapper(), result = FlightHapticSample.silent
        for _ in 0..<(hz * 2) {
            result = step(&mapper, sources: sources, dt: 1 / Double(hz),
                          velocity: velocity, acceleration: acceleration)
        }
        return result
    }

    func testProximityAndMotionDriveResponse() {
        let near = settled([source(x: 35)]), far = settled([source(x: 600)])
        XCTAssertGreaterThan(near.intensity, far.intensity + 0.25)
        let quiet = settled([], velocity: .zero)
        let fast = settled([], velocity: Vec2(x: 500, y: 0))
        let accelerating = settled([], acceleration: Vec2(x: 250, y: 0))
        let turning = settled([], acceleration: Vec2(x: 0, y: 250))
        XCTAssertGreaterThan(fast.intensity, quiet.intensity)
        XCTAssertGreaterThan(fast.sharpness, quiet.sharpness)
        XCTAssertGreaterThan(accelerating.intensity, fast.intensity)
        XCTAssertGreaterThan(turning.sharpness, accelerating.sharpness)
        XCTAssertFalse(quiet.shouldPulse)
    }

    func testSmoothingMatches30Through240Hz() {
        let expected = settled([source(x: 50)], hz: 30)
        for hz in [60, 120, 240] {
            let actual = settled([source(x: 50)], hz: hz)
            XCTAssertEqual(actual.intensity, expected.intensity, accuracy: 1e-12, "\(hz) Hz")
            XCTAssertEqual(actual.sharpness, expected.sharpness, accuracy: 1e-12, "\(hz) Hz")
            XCTAssertEqual(actual.dominantID, expected.dominantID)
        }
    }

    func testDominantSourceRequiresPersistentLead() {
        var mapper = FlightHapticMapper()
        let neighbors = [source("a", x: -100), source("b", x: 100)]
        XCTAssertEqual(step(&mapper, sources: neighbors).dominantID, "a")
        for index in 0..<120 {
            let offset = index.isMultiple(of: 2) ? 0.5 : -0.5
            XCTAssertEqual(step(&mapper, sources: neighbors, position: Vec2(x: offset, y: 0)).dominantID, "a")
        }
        let challenger = [source("a", x: -100), source("b", x: 40)]
        for _ in 0..<8 { XCTAssertEqual(step(&mapper, sources: challenger).dominantID, "a") }
        // Losing the lead resets the persistence window rather than accumulating noise.
        XCTAssertEqual(step(&mapper, sources: neighbors).dominantID, "a")
        for _ in 0..<8 { XCTAssertEqual(step(&mapper, sources: challenger).dominantID, "a") }
        XCTAssertEqual(step(&mapper, sources: challenger).dominantID, "b")
        XCTAssertEqual(step(&mapper, sources: [source("a", x: -100)]).dominantID, "a",
                       "Removing the old source must not retain an absent attractor")
    }

    func testPulseCadenceAndNormalizedBoundsAtEveryRate() {
        for hz in [30, 60, 120, 240] {
            var mapper = FlightHapticMapper(), previousPulse: Double?, pulseCount = 0
            for index in 1...(hz * 10) {
                let sample = step(&mapper, sources: [source(x: 20)], dt: 1 / Double(hz),
                                  velocity: Vec2(x: 600, y: 0), acceleration: Vec2(x: 300, y: 400))
                XCTAssertTrue(sample.intensity.isFinite)
                XCTAssertTrue((0...FlightHapticMapper.maximumIntensity).contains(sample.intensity))
                XCTAssertTrue(sample.sharpness.isFinite && (0...1).contains(sample.sharpness))
                if sample.shouldPulse {
                    let time = Double(index) / Double(hz)
                    if let previousPulse {
                        XCTAssertGreaterThanOrEqual(time - previousPulse,
                                                   FlightHapticMapper.minimumPulseInterval - 1e-12)
                    }
                    previousPulse = time
                    pulseCount += 1
                }
            }
            XCTAssertGreaterThan(pulseCount, 0)
            XCTAssertLessThanOrEqual(pulseCount, 40, "Bounded envelope starts, never a per-frame buzz")
        }
    }

    func testInactiveAndExplicitResetReturnFreshState() {
        var mapper = FlightHapticMapper()
        for _ in 0..<120 { _ = step(&mapper, sources: [source("old", x: 20)]) }
        XCTAssertEqual(step(&mapper, sources: [source("old", x: 20)], active: false), .silent)
        var fresh = FlightHapticMapper()
        XCTAssertEqual(step(&mapper, sources: [source("new", x: 70)]),
                       step(&fresh, sources: [source("new", x: 70)]))
        for _ in 0..<120 { _ = step(&mapper, sources: [source("old", x: 20)]) }
        mapper.reset() // Caller routes teleport, interruption and teardown through this.
        fresh.reset()
        XCTAssertEqual(step(&mapper, sources: [source("new", x: 70)]),
                       step(&fresh, sources: [source("new", x: 70)]))
    }

    func testNonfiniteInputsAndSuspensionReset() {
        var mapper = FlightHapticMapper()
        for dt in [Double.nan, .infinity, -.infinity, -1, 0, 0.251, 1] {
            _ = step(&mapper, sources: [source(x: 20)])
            XCTAssertEqual(step(&mapper, sources: [source(x: 20)], dt: dt), .silent)
        }
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(step(&mapper, sources: [], position: Vec2(x: value, y: 0)), .silent)
            XCTAssertEqual(step(&mapper, sources: [], velocity: Vec2(x: 0, y: value)), .silent)
            XCTAssertEqual(step(&mapper, sources: [], acceleration: Vec2(x: value, y: 0)), .silent)
        }
        var fresh = FlightHapticMapper()
        XCTAssertEqual(step(&mapper, sources: [source(x: 50)]), step(&fresh, sources: [source(x: 50)]))
    }

    func testMalformedAndLargeAttractorsStayFinite() {
        let invalid = [
            FlightHapticAttractor(id: "position", position: Vec2(x: .nan, y: 0), mass: 8, radius: 1),
            FlightHapticAttractor(id: "mass", position: .zero, mass: .nan, radius: 1),
            FlightHapticAttractor(id: "zero", position: .zero, mass: 0, radius: 1),
            FlightHapticAttractor(id: "radius", position: .zero, mass: 8, radius: -1)
        ]
        var mapper = FlightHapticMapper()
        let ignored = step(&mapper, sources: invalid)
        XCTAssertNil(ignored.dominantID)
        XCTAssertTrue(ignored.intensity.isFinite && ignored.sharpness.isFinite)
        let huge = step(&mapper, sources: [source(x: .greatestFiniteMagnitude)],
                        velocity: Vec2(x: .greatestFiniteMagnitude, y: -.greatestFiniteMagnitude),
                        acceleration: Vec2(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude))
        XCTAssertTrue(huge.intensity.isFinite && huge.sharpness.isFinite)
        XCTAssertTrue((0...FlightHapticMapper.maximumIntensity).contains(huge.intensity))
        XCTAssertTrue((0...1).contains(huge.sharpness))
    }

    func testPlayerAndTotalSourceCapsStillAllowFixedBodies() {
        var mapper = FlightHapticMapper()
        let holes = (0..<32).map { source("hole-\($0)", x: 500 + Double($0)) }
        XCTAssertEqual(step(&mapper, sources: holes + [source("over-limit", x: 14, mass: 100)]).dominantID, "hole-0")
        mapper.reset()
        XCTAssertEqual(step(&mapper, sources: holes + [source("fixed", x: 14, mass: 100, player: false)]).dominantID, "fixed")
        mapper.reset()
        let bodies = (0..<48).map { source("body-\($0)", x: 500 + Double($0), player: false) }
        XCTAssertEqual(step(&mapper, sources: bodies + [source("49th", x: 14, mass: 100, player: false)]).dominantID, "body-0")
    }
}
