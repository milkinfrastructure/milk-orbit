import Foundation

public struct Vec2: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let zero = Vec2(x: 0, y: 0)
    public var length: Double { (x * x + y * y).squareRoot() }
    public func distance(to other: Self) -> Double { (self - other).length }
    public static func + (lhs: Self, rhs: Self) -> Self { Self(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    public static func - (lhs: Self, rhs: Self) -> Self { Self(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    public static func * (lhs: Self, rhs: Double) -> Self { Self(x: lhs.x * rhs, y: lhs.y * rhs) }
    public static func / (lhs: Self, rhs: Double) -> Self { Self(x: lhs.x / rhs, y: lhs.y / rhs) }
}

public struct Hole: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var x: Double
    public var y: Double
    public var mass: Double
    public var position: Vec2 {
        get { Vec2(x: x, y: y) }
        set { x = newValue.x; y = newValue.y }
    }

    public init(id: UUID = UUID(), x: Double, y: Double, mass: Double) {
        self.id = id; self.x = x; self.y = y; self.mass = mass
    }
    public init(id: UUID = UUID(), position: Vec2, mass: Double) {
        self.init(id: id, x: position.x, y: position.y, mass: mass)
    }
    private enum CodingKeys: String, CodingKey { case id, x, y, mass }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        x = try values.decode(Double.self, forKey: .x)
        y = try values.decode(Double.self, forKey: .y)
        mass = try values.decode(Double.self, forKey: .mass)
    }
}

public struct OrbitMotion: Codable, Equatable, Sendable {
    public var cx: Double
    public var cy: Double
    public var radius: Double
    public var period: Double
    public var phase: Double?
    public init(cx: Double, cy: Double, radius: Double, period: Double, phase: Double? = nil) {
        self.cx = cx; self.cy = cy; self.radius = radius; self.period = period; self.phase = phase
    }
}

public struct PatrolMotion: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var period: Double
    public var phase: Double?
    public init(x: Double, y: Double, period: Double, phase: Double? = nil) {
        self.x = x; self.y = y; self.period = period; self.phase = phase
    }
}

public struct Ship: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var angle: Double?
    public var speed: Double
    public var position: Vec2 { Vec2(x: x, y: y) }
    public init(x: Double, y: Double, angle: Double? = nil, speed: Double) {
        self.x = x; self.y = y; self.angle = angle; self.speed = speed
    }
}

public struct Goal: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var r: Double
    public var orbit: OrbitMotion?
    public var patrol: PatrolMotion?
    public var position: Vec2 { Vec2(x: x, y: y) }
    public init(x: Double, y: Double, r: Double, orbit: OrbitMotion? = nil, patrol: PatrolMotion? = nil) {
        self.x = x; self.y = y; self.r = r; self.orbit = orbit; self.patrol = patrol
    }
}

public enum BodyType: String, Codable, Sendable {
    case hole, planet, repulsor, asteroid, wormhole
}

public struct Body: Codable, Equatable, Sendable {
    public var type: BodyType
    public var id: String?
    public var twin: String?
    public var x: Double
    public var y: Double
    public var r: Double
    public var mass: Double
    public var orbit: OrbitMotion?
    public var patrol: PatrolMotion?
    public var position: Vec2 { Vec2(x: x, y: y) }
    public init(type: BodyType, x: Double, y: Double, r: Double = 0, mass: Double = 0,
                id: String? = nil, twin: String? = nil, orbit: OrbitMotion? = nil, patrol: PatrolMotion? = nil) {
        self.type = type; self.id = id; self.twin = twin; self.x = x; self.y = y
        self.r = r; self.mass = mass; self.orbit = orbit; self.patrol = patrol
    }
    private enum CodingKeys: String, CodingKey { case type, id, twin, x, y, r, mass, orbit, patrol }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(BodyType.self, forKey: .type)
        id = try values.decodeIfPresent(String.self, forKey: .id)
        twin = try values.decodeIfPresent(String.self, forKey: .twin)
        x = try values.decode(Double.self, forKey: .x)
        y = try values.decode(Double.self, forKey: .y)
        r = try values.decodeIfPresent(Double.self, forKey: .r) ?? 0
        mass = try values.decodeIfPresent(Double.self, forKey: .mass) ?? 0
        orbit = try values.decodeIfPresent(OrbitMotion.self, forKey: .orbit)
        patrol = try values.decodeIfPresent(PatrolMotion.self, forKey: .patrol)
    }
}

public struct Beacon: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var r: Double
    public var position: Vec2 { Vec2(x: x, y: y) }
    public init(x: Double, y: Double, r: Double) { self.x = x; self.y = y; self.r = r }
}

public struct Zone: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
}

public struct Level: Codable, Equatable, Sendable {
    public var name: String
    public var hint: String
    public var matter: Double
    public var limit: Int?
    public var answer: [Hole]
    public var ship: Ship
    public var goal: Goal
    public var bodies: [Body]
    public var beacons: [Beacon]
    public var zones: [Zone]
    public var solution: [Hole] { answer }

    public init(name: String, hint: String = "", matter: Double, answer: [Hole] = [],
                ship: Ship, goal: Goal, bodies: [Body] = [], beacons: [Beacon] = [],
                zones: [Zone] = [], limit: Int? = nil) {
        self.name = name; self.hint = hint; self.matter = matter; self.limit = limit
        self.answer = answer; self.ship = ship; self.goal = goal
        self.bodies = bodies; self.beacons = beacons; self.zones = zones
    }
    private enum CodingKeys: String, CodingKey { case name, hint, matter, limit, answer, ship, goal, bodies, beacons, zones }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        hint = try values.decode(String.self, forKey: .hint)
        matter = try values.decode(Double.self, forKey: .matter)
        limit = try values.decodeIfPresent(Int.self, forKey: .limit)
        answer = try values.decodeIfPresent([Hole].self, forKey: .answer) ?? []
        ship = try values.decode(Ship.self, forKey: .ship)
        goal = try values.decode(Goal.self, forKey: .goal)
        bodies = try values.decode([Body].self, forKey: .bodies)
        beacons = try values.decodeIfPresent([Beacon].self, forKey: .beacons) ?? []
        zones = try values.decodeIfPresent([Zone].self, forKey: .zones) ?? []
    }
}

public enum FlightStatus: String, Codable, Sendable {
    case flying, imploded, crashed, won, lost, stranded
}

public enum CollisionCause: Codable, Equatable, Sendable {
    case playerHole(Hole)
    case body(Body)
}

public struct PortalJump: Codable, Equatable, Sendable {
    public var from: Body
    public var to: Body
}

public struct Flight: Codable, Equatable, Sendable {
    public var time: Double = 0
    public var x: Double
    public var y: Double
    public var vx: Double
    public var vy: Double
    public var status: FlightStatus = .flying
    public var cause: CollisionCause?
    public var portal: String?
    public var jumped: PortalJump?
    public var jumps: Int = 0
    public var passed: [Bool]
    public var left: Int
    public var reached: Beacon?
    public var closest: Double = .infinity
    public var position: Vec2 { Vec2(x: x, y: y) }
    public var velocity: Vec2 { Vec2(x: vx, y: vy) }

    public init(x: Double, y: Double, vx: Double, vy: Double, beaconCount: Int = 0) {
        self.x = x; self.y = y; self.vx = vx; self.vy = vy
        passed = Array(repeating: false, count: beaconCount)
        left = beaconCount
    }
}

// `closest == .infinity` means no distance sample yet. JSON represents that
// sentinel as null; all other simulation values remain exact doubles.
extension Flight {
    private enum CodingKeys: String, CodingKey {
        case time, x, y, vx, vy, status, cause, portal, jumped, jumps, passed, left, reached, closest
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Double.self, forKey: .time)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        vx = try c.decode(Double.self, forKey: .vx)
        vy = try c.decode(Double.self, forKey: .vy)
        status = try c.decode(FlightStatus.self, forKey: .status)
        cause = try c.decodeIfPresent(CollisionCause.self, forKey: .cause)
        portal = try c.decodeIfPresent(String.self, forKey: .portal)
        jumped = try c.decodeIfPresent(PortalJump.self, forKey: .jumped)
        jumps = try c.decode(Int.self, forKey: .jumps)
        passed = try c.decode([Bool].self, forKey: .passed)
        left = try c.decode(Int.self, forKey: .left)
        reached = try c.decodeIfPresent(Beacon.self, forKey: .reached)
        closest = try c.decodeIfPresent(Double.self, forKey: .closest) ?? .infinity
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(time, forKey: .time)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(vx, forKey: .vx)
        try c.encode(vy, forKey: .vy)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(cause, forKey: .cause)
        try c.encodeIfPresent(portal, forKey: .portal)
        try c.encodeIfPresent(jumped, forKey: .jumped)
        try c.encode(jumps, forKey: .jumps)
        try c.encode(passed, forKey: .passed)
        try c.encode(left, forKey: .left)
        try c.encodeIfPresent(reached, forKey: .reached)
        if closest == .infinity { try c.encodeNil(forKey: .closest) }
        else { try c.encode(closest, forKey: .closest) }
    }
}
