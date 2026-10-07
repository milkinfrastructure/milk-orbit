import XCTest
@testable import OrbitCore

final class CompactCabinetRegressionTests: XCTestCase {
    func testPortrait17ProCompactReservation() {
        let safe = CGRect(x: 0, y: 62, width: 402, height: 778)
        let layout = CabinetLayout(area: safe, consoleHeight: 96, headerHeight: 72)
        XCTAssertTrue(layout.portraitBoard)
        XCTAssertFalse(layout.sideConsole)
        XCTAssertEqual(layout.field.minX, 36.1875, accuracy: 1e-9)
        XCTAssertEqual(layout.field.minY, 137, accuracy: 1e-9)
        XCTAssertEqual(layout.field.width, 329.625, accuracy: 1e-9)
        XCTAssertEqual(layout.field.height, 586, accuracy: 1e-9)
        XCTAssertGreaterThan(layout.field.width * layout.field.height, 193_000)
        XCTAssertEqual(layout.console.height, 96)
        XCTAssertEqual(layout.header.height, 68)
        XCTAssertTrue(safe.contains(layout.field))
        XCTAssertLessThanOrEqual(layout.header.maxY, layout.field.minY)
        XCTAssertLessThanOrEqual(layout.field.maxY, layout.console.minY)
    }

    func testBothOrientationsUseLargestAspectFitAndAllWorldCornersRoundTrip() {
        for safe in [CGRect(x: 0, y: 62, width: 402, height: 778),
                     CGRect(x: 62, y: 0, width: 778, height: 402)] {
            let layout = CabinetLayout(area: safe, consoleHeight: 96, headerHeight: 72)
            let field = layout.field
            let inner = layout.fieldSurround.insetBy(dx: 3, dy: 3)
            XCTAssertTrue(inner.contains(field))
            XCTAssertEqual(field.midX, inner.midX, accuracy: 1e-9)
            XCTAssertEqual(field.midY, inner.midY, accuracy: 1e-9)
            XCTAssertTrue(abs(field.width-inner.width) < 1e-9 || abs(field.height-inner.height) < 1e-9,
                          "At least one dimension must fill its available interior; otherwise the complete world can grow.")
            XCTAssertEqual(field.width/field.height, layout.portraitBoard ? 9.0/16 : 16.0/9, accuracy: 1e-9)
            let mapping = BoardTransform(width: field.width, height: field.height, portrait: layout.portraitBoard)
            let world = [Vec2(x: 0, y: 0), Vec2(x: 1600, y: 0), Vec2(x: 0, y: 900), Vec2(x: 1600, y: 900)]
            let expected = layout.portraitBoard
                ? [Vec2(x: 0, y: field.height), Vec2(x: 0, y: 0), Vec2(x: field.width, y: field.height), Vec2(x: field.width, y: 0)]
                : [Vec2(x: 0, y: 0), Vec2(x: field.width, y: 0), Vec2(x: 0, y: field.height), Vec2(x: field.width, y: field.height)]
            for (point, corner) in zip(world, expected) {
                let screen = mapping.screenPoint(point)
                XCTAssertEqual(screen.x, corner.x, accuracy: 1e-9)
                XCTAssertEqual(screen.y, corner.y, accuracy: 1e-9)
                let global = Vec2(x: screen.x+field.minX, y: screen.y+field.minY)
                let restored = mapping.worldPoint(Vec2(x: global.x-field.minX, y: global.y-field.minY))
                XCTAssertEqual(restored.x, point.x, accuracy: 1e-9)
                XCTAssertEqual(restored.y, point.y, accuracy: 1e-9)
            }
        }
    }
}
