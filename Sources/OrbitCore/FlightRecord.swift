import Foundation

/// One historical docking, independent of the board subsequently edited or loaded.
/// This is presentation evidence, not an additive award or a campaign-score ledger.
public struct FlightRecord: Codable, Equatable, Sendable {
    public let sectorIndex: Int
    public let sectorCount: Int
    public let sectorName: String
    public let holes: Int
    public let pull: Double
    public let budget: Double
    public let launches: Int
    public let assisted: Bool

    public var isFinalSector: Bool { sectorIndex == sectorCount - 1 }
    public var isValid: Bool {
        sectorCount > 0 && sectorIndex >= 0 && sectorIndex < sectorCount
            && !sectorName.isEmpty && holes >= 0 && holes <= 32
            && pull.isFinite && pull >= 0 && budget.isFinite && budget >= 0
            && pull <= budget + 0.000001 && launches > 0
    }

    public init?(session: GameSession, sectorIndex: Int, sectorCount: Int) {
        guard session.phase == .finished, session.flight?.status == .won else { return nil }
        self.sectorIndex = sectorIndex
        self.sectorCount = sectorCount
        sectorName = session.level.name
        holes = session.holes.count
        pull = session.holes.reduce(0) { $0 + $1.mass }
        budget = session.level.matter
        launches = session.launches
        assisted = session.assisted
        guard isValid else { return nil }
    }
}
