import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Geometry only. `area` already excludes safe areas; reserved rectangles are in
/// the same coordinate space and already include any required clearance.
public struct CabinetLayout: Sendable {
    public let field: CGRect
    public let fieldSurround: CGRect
    public let console: CGRect
    public let header: CGRect
    public let sideConsole: Bool
    public let portraitBoard: Bool

    /// The side/divided header is contained in `console`: reserve its height
    /// before laying out scrollable dock content. An ordinary bottom layout has
    /// its header above the board, separate from the bottom console.
    public init(area: CGRect, consoleWidth: CGFloat = 168, consoleHeight: CGFloat = 140,
                headerHeight: CGFloat = 70, panelOpen: Bool = false,
                divisions: [CGRect] = [], occlusions: [CGRect] = []) {
        let area = Self.valid(area)
        let divisions = divisions.compactMap { Self.overlap(Self.valid($0), area) }
        let blocked = (occlusions + divisions).compactMap { Self.overlap(Self.valid($0), area) }
        let headerHeight = headerHeight.isFinite ? max(0, headerHeight) : 70
        let dockWidth = consoleWidth.isFinite ? max(0, consoleWidth) : 168
        let dockHeight = consoleHeight.isFinite ? max(0, consoleHeight) : 140
        var candidates: [Candidate] = []

        for division in divisions {
            let vertical = division.height >= division.width
            let boardPane = vertical
                ? CGRect(x: area.minX, y: area.minY, width: division.minX - area.minX, height: area.height)
                : CGRect(x: area.minX, y: area.minY, width: area.width, height: division.minY - area.minY)
            let dockPane = vertical
                ? CGRect(x: division.maxX, y: area.minY, width: area.maxX - division.maxX, height: area.height)
                : CGRect(x: area.minX, y: division.maxY, width: area.width, height: area.maxY - division.maxY)
            let dock = Self.clear(Self.inset(dockPane, x: 8, y: 8), avoiding: blocked)
            let surround = Self.clear(Self.inset(boardPane, x: 8, y: 8), avoiding: blocked)
            candidates.append(Candidate(surround: surround, console: dock,
                header: CGRect(x: dock.minX, y: dock.minY, width: dock.width, height: min(headerHeight, dock.height)),
                side: vertical, portrait: boardPane.height >= boardPane.width))
        }

        if candidates.isEmpty {
            let width = min(area.width, panelOpen ? max(dockWidth, min(280, area.width * 0.35)) : dockWidth)
            let side = area.width >= 600 && area.width > area.height && area.width - width - 36 >= 240
            let portrait = area.height >= area.width
            let dock: CGRect
            let header: CGRect
            let boardPane: CGRect
            if side {
                dock = Self.clear(CGRect(x: area.maxX - width - 8, y: area.minY + 6,
                                          width: width, height: max(0, area.height - 12)), avoiding: blocked)
                header = CGRect(x: dock.minX, y: dock.minY, width: dock.width, height: min(headerHeight, dock.height))
                boardPane = CGRect(x: area.minX + 8, y: area.minY + 6,
                                   width: max(0, area.width - width - 30), height: max(0, area.height - 12))
            } else {
                let height = min(max(0, area.height - 16), panelOpen ? max(dockHeight, min(340, area.height * 0.5)) : dockHeight)
                let rawDock = CGRect(x: area.minX + min(12, area.width / 2), y: area.maxY - min(8, area.height / 2) - height,
                                     width: max(0, area.width - 24), height: height)
                dock = Self.clear(rawDock, avoiding: blocked)
                let headerTop = area.minY + min(4, area.height / 2)
                let rawHeader = CGRect(x: area.minX + min(12, area.width / 2), y: headerTop,
                    width: max(0, area.width - 24), height: min(max(0, headerHeight - 4), max(0, rawDock.minY - 10 - headerTop)))
                header = Self.clear(rawHeader, avoiding: blocked)
                boardPane = CGRect(x: area.minX + min(8, area.width / 2), y: rawHeader.maxY,
                    width: max(0, area.width - 16), height: max(0, rawDock.minY - 10 - rawHeader.maxY))
            }
            candidates.append(Candidate(surround: Self.clear(boardPane, avoiding: blocked),
                                        console: dock, header: header, side: side, portrait: portrait))
        }

        // Multiple active divisions can yield several pairs of panes. Prefer a
        // usable dock, then the largest complete world; never bridge a division.
        let result = candidates.max {
            if $0.usableDock != $1.usableDock { return !$0.usableDock }
            return $0.field.width * $0.field.height < $1.field.width * $1.field.height
        }!
        field = result.field; fieldSurround = result.surround
        console = result.console; header = result.header
        sideConsole = result.side; portraitBoard = result.portrait
    }

    private struct Candidate {
        let surround: CGRect
        let console: CGRect
        let header: CGRect
        let side: Bool
        let portrait: Bool
        var usableDock: Bool { console.width >= 44 && console.height >= 44 }
        var field: CGRect {
            let space = CabinetLayout.inset(surround, x: 3, y: 3)
            let aspect: CGFloat = portrait ? 9.0 / 16 : 16.0 / 9
            let width = max(0, min(space.width, space.height * aspect))
            return CGRect(x: space.midX - width / 2, y: space.midY - width / aspect / 2,
                          width: width, height: width / aspect)
        }
    }

    private static func valid(_ rect: CGRect) -> CGRect {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.size.width.isFinite, rect.size.height.isFinite else { return .zero }
        return CGRect(x: rect.origin.x, y: rect.origin.y, width: max(0, rect.size.width), height: max(0, rect.size.height))
    }
    private static func inset(_ rect: CGRect, x: CGFloat, y: CGFloat) -> CGRect {
        rect.insetBy(dx: min(x, rect.width / 2), dy: min(y, rect.height / 2))
    }
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGRect? {
        let intersection = a.intersection(b)
        return intersection.isNull || intersection.width <= 0 || intersection.height <= 0 ? nil : intersection
    }

    /// A full-screen presentation may expand beyond the gameplay dock, while
    /// still occupying one continuous, usable pane. Out-of-bounds system regions
    /// (for example an island already excluded by safe areas) cost no space.
    public static func presentationArea(in area: CGRect, avoiding reserved: [CGRect]) -> CGRect {
        clear(valid(area), avoiding: reserved.map(valid))
    }

    /// Largest axis-aligned empty rectangle. Candidate x edges come from the
    /// pane/occlusions; each x span only needs the gaps in merged y intervals.
    private static func clear(_ pane: CGRect, avoiding blocked: [CGRect]) -> CGRect {
        let blocks = blocked.compactMap { overlap($0, pane) }
        guard !blocks.isEmpty else { return pane }
        let edges = Array(Set([pane.minX, pane.maxX] + blocks.flatMap { [$0.minX, $0.maxX] })).sorted()
        var best = CGRect(x: pane.minX, y: pane.minY, width: 0, height: 0)
        for left in edges.indices {
            for right in edges.indices where right > left {
                let low = edges[left], high = edges[right]
                let intervals = blocks.filter { $0.minX < high && $0.maxX > low }.sorted { $0.minY < $1.minY }
                var top = pane.minY
                func consider(_ bottom: CGFloat) {
                    let rect = CGRect(x: low, y: top, width: high - low, height: max(0, bottom - top))
                    if rect.width * rect.height > best.width * best.height { best = rect }
                }
                for block in intervals { consider(block.minY); top = max(top, block.maxY) }
                consider(pane.maxY)
            }
        }
        return best
    }
}
