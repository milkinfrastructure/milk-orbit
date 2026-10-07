import Foundation

/// Fixed-step port of the reference game's numerical rules. Rendering and input never
/// influence the simulation interval, so one arrangement always produces one flight.
public enum Physics {
    public static let worldWidth: Double = 1600
    public static let worldHeight: Double = 900
    public static let worldMargin: Double = 240
    public static let stepDuration: Double = 1.0 / 240.0
    public static let shipRadius: Double = 7
    public static let flightLimit: Double = 45
    public static let minMass: Double = 2
    public static let maxHoles = 32
    public static let growRate: Double = 26
    public static let startClearance: Double = 70
    public static let clearance: Double = 8
    private static let pullStrength: Double = 100_000
    private static let softening: Double = 6

    public static func horizonRadius(mass: Double) -> Double { 7 + 2.3 * mass.squareRoot() }

    public static func massForHorizon(radius: Double) -> Double {
        let root = max(radius - 7, 0) / 2.3
        return root * root
    }

    private static func position(x: Double, y: Double, orbit: OrbitMotion?, patrol: PatrolMotion?, time: Double) -> Vec2 {
        if let orbit {
            let angle = 2 * Double.pi * (time / orbit.period + (orbit.phase ?? 0))
            return Vec2(x: orbit.cx + orbit.radius * cos(angle), y: orbit.cy + orbit.radius * sin(angle))
        }
        if let patrol {
            let swing = 0.5 - 0.5 * cos(2 * Double.pi * (time / patrol.period + (patrol.phase ?? 0)))
            return Vec2(x: x + (patrol.x - x) * swing, y: y + (patrol.y - y) * swing)
        }
        return Vec2(x: x, y: y)
    }

    public static func bodyAt(body: Body, time: Double) -> Vec2 {
        position(x: body.x, y: body.y, orbit: body.orbit, patrol: body.patrol, time: time)
    }

    public static func goalAt(level: Level, time: Double) -> Vec2 {
        let goal = level.goal
        return position(x: goal.x, y: goal.y, orbit: goal.orbit, patrol: goal.patrol, time: time)
    }

    public static func launch(level: Level) -> Flight {
        let angle = ((level.ship.angle ?? 0) * Double.pi) / 180
        return Flight(x: level.ship.x, y: level.ship.y,
                      vx: cos(angle) * level.ship.speed, vy: sin(angle) * level.ship.speed,
                      beaconCount: level.beacons.count)
    }

    @discardableResult
    private static func pullTowards(point: Vec2, x: Double, y: Double, mass: Double, pull: inout Vec2) -> Double {
        let dx = x - point.x
        let dy = y - point.y
        let squared = dx * dx + dy * dy
        let distance = squared == 0 ? 1 : squared.squareRoot()
        let strength = (pullStrength * mass) / (squared + softening * softening)
        pull.x += (strength * dx) / distance
        pull.y += (strength * dy) / distance
        return distance
    }

    public static func pullAt(level: Level, holes: [Hole], x: Double, y: Double, time: Double) -> Vec2 {
        var pull = Vec2.zero
        let point = Vec2(x: x, y: y)
        for hole in holes { pullTowards(point: point, x: hole.x, y: hole.y, mass: hole.mass, pull: &pull) }
        for body in level.bodies where body.mass != 0 {
            let at = bodyAt(body: body, time: time)
            pullTowards(point: point, x: at.x, y: at.y,
                        mass: body.type == .repulsor ? -body.mass : body.mass, pull: &pull)
        }
        return pull
    }

    public static func becalmed(level: Level, holes: [Hole]) -> Bool {
        if level.ship.speed > 0 { return false }
        let pull = pullAt(level: level, holes: holes, x: level.ship.x, y: level.ship.y, time: 0)
        return pull.x * pull.x + pull.y * pull.y < 1e-6
    }

    public static func step(level: Level, holes: [Hole], flight: inout Flight) {
        guard flight.status == .flying else { return }
        var pull = Vec2.zero
        let time = flight.time
        flight.jumped = nil
        flight.reached = nil

        for hole in holes {
            if pullTowards(point: flight.position, x: hole.x, y: hole.y, mass: hole.mass, pull: &pull) < horizonRadius(mass: hole.mass) {
                flight.status = .imploded
                flight.cause = .playerHole(hole)
                return
            }
        }

        for body in level.bodies {
            let at = bodyAt(body: body, time: time)
            let dx = at.x - flight.x
            let dy = at.y - flight.y
            switch body.type {
            case .hole:
                if pullTowards(point: flight.position, x: at.x, y: at.y, mass: body.mass, pull: &pull) < horizonRadius(mass: body.mass) {
                    flight.status = .imploded; flight.cause = .body(body); return
                }
            case .planet, .repulsor:
                let mass = body.type == .repulsor ? -body.mass : body.mass
                if pullTowards(point: flight.position, x: at.x, y: at.y, mass: mass, pull: &pull) < body.r + shipRadius {
                    flight.status = .crashed; flight.cause = .body(body); return
                }
            case .asteroid:
                let reach = body.r + shipRadius
                if dx * dx + dy * dy < reach * reach {
                    flight.status = .crashed; flight.cause = .body(body); return
                }
            case .wormhole:
                let inside = dx * dx + dy * dy < body.r * body.r
                if inside && flight.portal != body.id,
                   let twin = level.bodies.first(where: { $0.type == .wormhole && $0.id == body.twin }) {
                    let exit = bodyAt(body: twin, time: time)
                    flight.x = exit.x; flight.y = exit.y
                    flight.portal = twin.id
                    flight.jumped = PortalJump(from: body, to: twin)
                    flight.jumps += 1
                    flight.time += stepDuration
                    return
                }
                if !inside && flight.portal == body.id { flight.portal = nil }
            }
        }

        flight.vx += pull.x * stepDuration
        flight.vy += pull.y * stepDuration
        flight.x += flight.vx * stepDuration
        flight.y += flight.vy * stepDuration
        flight.time += stepDuration

        var next = Double.infinity
        for i in flight.passed.indices where !flight.passed[i] {
            let beacon = level.beacons[i]
            let bx = beacon.x - flight.x
            let by = beacon.y - flight.y
            let distance = (bx * bx + by * by).squareRoot()
            if distance < beacon.r {
                flight.passed[i] = true
                flight.left -= 1
                flight.reached = beacon
                flight.closest = .infinity
                next = .infinity
                break
            }
            if distance < next { next = distance }
        }

        let goal = goalAt(level: level, time: flight.time)
        let gx = goal.x - flight.x
        let gy = goal.y - flight.y
        let toGoal = (gx * gx + gy * gy).squareRoot()
        if flight.left == 0 { next = toGoal }
        if flight.reached == nil && next < flight.closest { flight.closest = next }

        if flight.left == 0 && toGoal < level.goal.r {
            flight.status = .won
        } else if flight.x < -worldMargin || flight.x > worldWidth + worldMargin ||
                    flight.y < -worldMargin || flight.y > worldHeight + worldMargin {
            flight.status = .lost
        } else if flight.time > flightLimit {
            flight.status = .stranded
        }
    }

    public static func fly(level: Level, holes: [Hole]) -> Flight {
        var flight = launch(level: level)
        while flight.status == .flying { step(level: level, holes: holes, flight: &flight) }
        return flight
    }

    public static func roomAt(level: Level, holes: [Hole], x: Double, y: Double) -> Double {
        var room = min(x, y, worldWidth - x, worldHeight - y) - clearance
        let startX = x - level.ship.x
        let startY = y - level.ship.y
        room = min(room, (startX * startX + startY * startY).squareRoot() - startClearance)

        if level.goal.orbit == nil && level.goal.patrol == nil {
            let dx = x - level.goal.x
            let dy = y - level.goal.y
            room = min(room, (dx * dx + dy * dy).squareRoot() - level.goal.r - clearance)
        }
        for beacon in level.beacons {
            let dx = x - beacon.x
            let dy = y - beacon.y
            room = min(room, (dx * dx + dy * dy).squareRoot() - beacon.r - clearance)
        }
        for zone in level.zones {
            let dx = max(zone.x - x, 0, x - (zone.x + zone.w))
            let dy = max(zone.y - y, 0, y - (zone.y + zone.h))
            room = min(room, (dx * dx + dy * dy).squareRoot() - clearance)
        }
        for hole in holes {
            let dx = x - hole.x
            let dy = y - hole.y
            room = min(room, (dx * dx + dy * dy).squareRoot() - horizonRadius(mass: hole.mass) - clearance)
        }
        for body in level.bodies where body.orbit == nil && body.patrol == nil {
            let dx = x - body.x
            let dy = y - body.y
            let radius = body.type == .hole ? horizonRadius(mass: body.mass) : body.r
            room = min(room, (dx * dx + dy * dy).squareRoot() - radius - clearance)
        }
        return room
    }

    /// Pass all *other* holes when resizing an existing hole. Its current matter
    /// then returns to the budget, while the same geometry restrictions still apply.
    public static func capacityAt(level: Level, holes: [Hole], x: Double, y: Double) -> Double {
        if holes.count >= holeLimit(for: level) { return 0 }
        let left = level.matter - holes.reduce(0) { $0 + $1.mass }
        let fits = massForHorizon(radius: roomAt(level: level, holes: holes, x: x, y: y))
        let most = min(left, fits)
        return most >= minMass - 1e-9 ? most : 0
    }

    public static func holeLimit(for level: Level) -> Int {
        min(maxHoles, level.limit.flatMap { $0 > 0 ? $0 : nil } ?? maxHoles)
    }

    public static func placementReason(level: Level, holes: [Hole], at p: Vec2) -> String {
        if holes.count >= holeLimit(for: level) {
            return level.limit.map { $0 > 0 && $0 < maxHoles } == true
                ? "This sector allows \(holeLimit(for: level)) \(holeLimit(for: level) == 1 ? "hole" : "holes"). Remove one to add another."
                : "32-hole limit reached. Remove one to add another."
        }
        if level.matter - holes.reduce(0, { $0 + $1.mass }) < minMass - 1e-9 {
            return "Not enough strength left. Each new hole needs 2. Reduce or remove a hole."
        }
        if level.zones.contains(where: { p.x >= $0.x && p.x <= $0.x + $0.w && p.y >= $0.y && p.y <= $0.y + $0.h }) {
            return "Hatched zone: holes cannot be placed here."
        }
        return "Not enough clearance. Move away from the edge, ship or other objects."
    }
}
