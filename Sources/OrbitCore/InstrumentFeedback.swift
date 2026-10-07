import Foundation

/// Bounded event arbitration for the cabinet display. Time is supplied by the UI;
/// the model owns no timer and never queues stale messages behind a result.
public struct InstrumentFeedback: Sendable {
    public enum Lamp: Sendable { case off, green, red }
    public struct Message: Sendable {
        public let text: String
        public let announcement: String
        public let lamp: Lamp
        public let priority: Int
        public let expires: Double
        public let lampExpires: Double
    }
    public private(set) var message: Message?
    public init() {}
    @discardableResult
    public mutating func post(_ text: String, announcement: String, lamp: Lamp,
                              priority: Int, now: Double, duration: Double = 2.4) -> Bool {
        guard now.isFinite, duration.isFinite, duration > 0 else { return false }
        if let current = message, current.expires > now, current.priority > priority { return false }
        message = Message(text:text,announcement:announcement,lamp:lamp,priority:priority,
                          expires:now+duration,lampExpires:now+min(0.65,duration))
        return true
    }
    public func visible(at now: Double) -> Message? {
        guard let message, message.expires > now else { return nil }
        return message
    }
    public func lamp(at now: Double) -> Lamp {
        guard let message = visible(at:now), message.lampExpires > now else { return .off }
        return message.lamp
    }
    public func nextDeadline(after now: Double) -> Double? {
        guard let message = visible(at:now) else { return nil }
        return message.lampExpires > now ? message.lampExpires : message.expires
    }
    public mutating func clear() { message = nil }
}
