import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import OrbitCore

final class CabinetLayoutTests: XCTestCase {
    func testExpandedPresentationKeepsAreaWhenIslandIsOutsideSafeBounds() {
        let safe = CGRect(x: 16, y: 72, width: 370, height: 760)
        let island = CGRect(x: 150, y: 10, width: 100, height: 38)
        XCTAssertEqual(CabinetLayout.presentationArea(in: safe, avoiding: [island]), safe)
    }
    func testExpandedPresentationUsesOneClearPaneWithoutDiscardingItsHeight() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let hinge = CGRect(x: 490, y: 0, width: 20, height: 800)
        let result = CabinetLayout.presentationArea(in: area, avoiding: [hinge])
        XCTAssertTrue(area.contains(result))
        XCTAssertFalse(overlaps(result, hinge))
        XCTAssertEqual(result.width, 490)
        XCTAssertEqual(result.height, 800)
        let notch = CGRect(x: 400, y: 0, width: 200, height: 48)
        XCTAssertEqual(CabinetLayout.presentationArea(in: area, avoiding: [notch]),
            CGRect(x: 0, y: 48, width: 1000, height: 752))
    }
    private func verify(_ layout: CabinetLayout, in area: CGRect, avoiding blocks: [CGRect] = [],
                        file: StaticString = #filePath, line: UInt = #line) {
        for frame in [layout.field, layout.fieldSurround, layout.console, layout.header] {
            XCTAssertTrue(frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.width, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.height, 0, file: file, line: line)
            if !frame.isEmpty { XCTAssertTrue(area.contains(frame), "Outside safe area: \(frame)", file: file, line: line) }
            for block in blocks { XCTAssertFalse(overlaps(frame, block), "Reserved region crossed: \(frame)", file: file, line: line) }
        }
        XCTAssertFalse(overlaps(layout.field, layout.console), file: file, line: line)
        XCTAssertFalse(overlaps(layout.field, layout.header), file: file, line: line)
        if layout.field.height > 0 {
            XCTAssertEqual(layout.field.width / layout.field.height, layout.portraitBoard ? 9.0 / 16 : 16.0 / 9, accuracy: 0.000001, file: file, line: line)
        }
    }
    private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        return !intersection.isNull && intersection.width > 0.000001 && intersection.height > 0.000001
    }
    func testNormalNarrowShortAndNearSquareWindows() {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 568, height: 320),
                     CGSize(width: 600, height: 240), CGSize(width: 800, height: 780),
                     CGSize(width: 780, height: 800), CGSize(width: 1024, height: 768)] {
            let area = CGRect(origin: .zero, size: size)
            for panel in [false, true] { verify(CabinetLayout(area: area, panelOpen: panel), in: area) }
        }
        XCTAssertFalse(CabinetLayout(area: CGRect(x: 0, y: 0, width: 568, height: 320)).sideConsole)
        XCTAssertFalse(CabinetLayout(area: CGRect(x: 0, y: 0, width: 568, height: 320)).portraitBoard)
        XCTAssertTrue(CabinetLayout(area: CGRect(x: 0, y: 0, width: 800, height: 780)).sideConsole)
    }
    func testAsymmetricSafeAreaAndIncreasedContentSizes() {
        let area = CGRect(x: 61, y: 18, width: 805, height: 354)
        let layout = CabinetLayout(area: area, consoleWidth: 230, consoleHeight: 210, headerHeight: 90)
        verify(layout, in: area)
        XCTAssertEqual(layout.console.width, 230)
        XCTAssertEqual(layout.header.height, 90)
    }
    func testVerticalAndHorizontalDivisionsUseSeparatePanes() {
        for division in [CGRect(x: 490, y: 0, width: 20, height: 800),
                         CGRect(x: 0, y: 390, width: 1000, height: 20)] {
            let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
            let layout = CabinetLayout(area: area, divisions: [division])
            verify(layout, in: area, avoiding: [division])
            if division.height > division.width {
                XCTAssertLessThanOrEqual(layout.field.maxX, division.minX)
                XCTAssertGreaterThanOrEqual(layout.console.minX, division.maxX)
            } else {
                XCTAssertLessThanOrEqual(layout.field.maxY, division.minY)
                XCTAssertGreaterThanOrEqual(layout.console.minY, division.maxY)
            }
            XCTAssertTrue(layout.console.contains(layout.header))
        }
    }
    func testSeveralDivisionsAndOcclusionsNeverSplitWorld() {
        let area = CGRect(x: 10, y: 20, width: 1000, height: 800)
        let divisions = [CGRect(x: 490, y: 20, width: 20, height: 800), CGRect(x: 10, y: 390, width: 1000, height: 20)]
        let occlusions = [CGRect(x: 10, y: 20, width: 70, height: 200), CGRect(x: 820, y: 550, width: 190, height: 270)]
        verify(CabinetLayout(area: area, divisions: divisions, occlusions: occlusions), in: area, avoiding: divisions + occlusions)
    }
    func testOcclusionSelectsLargestRemainingRectangle() {
        let area = CGRect(x: 0, y: 0, width: 800, height: 500)
        let block = CGRect(x: 8, y: 6, width: 100, height: 200)
        let layout = CabinetLayout(area: area, occlusions: [block])
        verify(layout, in: area, avoiding: [block])
        // Remaining full-height right strip is 502×488; bottom strip is 602×288.
        XCTAssertEqual(layout.fieldSurround, CGRect(x: 108, y: 6, width: 502, height: 488))
    }
    func testZeroTinyAndFullyOccludedAreasStayFinite() {
        for size in [CGSize.zero, CGSize(width: 1, height: 1), CGSize(width: 100, height: 80)] {
            let area = CGRect(x: 30, y: 40, width: size.width, height: size.height)
            verify(CabinetLayout(area: area), in: area)
            verify(CabinetLayout(area: area, occlusions: [area]), in: area, avoiding: [area])
        }
    }
}
