import Foundation

/// Invertible presentation mapping. The logical world and physics do not rotate or resize.
/// Both axes fill the available safe-screen area, so touch input has no letterbox dead bands.
public struct BoardTransform: Sendable {
    public let width: Double
    public let height: Double
    public let portrait: Bool
    public init(width: Double, height: Double, portrait: Bool? = nil) {
        self.width = max(1, width); self.height = max(1, height)
        self.portrait = portrait ?? (height > width)
    }
    public func screenPoint(_ p: Vec2) -> Vec2 {
        portrait ? Vec2(x: p.y / Physics.worldHeight * width,
                        y: (1 - p.x / Physics.worldWidth) * height)
            : Vec2(x: p.x / Physics.worldWidth * width, y: p.y / Physics.worldHeight * height)
    }
    public func worldPoint(_ p: Vec2) -> Vec2 {
        portrait ? Vec2(x: (1 - p.y / height) * Physics.worldWidth,
                        y: p.x / width * Physics.worldHeight)
            : Vec2(x: p.x / width * Physics.worldWidth, y: p.y / height * Physics.worldHeight)
    }
    public func hitHole(in holes: [Hole], at screen: Vec2, minimumRadius: Double = 30) -> Hole? {
        let world = worldPoint(screen)
        return holes.filter { hole in
            screenPoint(hole.position).distance(to: screen) <= minimumRadius
                || hole.position.distance(to: world) <= Physics.horizonRadius(mass: hole.mass) + 6
        }.min { screenPoint($0.position).distance(to: screen) < screenPoint($1.position).distance(to: screen) }
    }
}
