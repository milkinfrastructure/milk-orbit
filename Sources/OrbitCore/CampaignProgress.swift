import Foundation

/// Explicit campaign-only reset policy. Preferences and learned controls survive.
/// The owner must invalidate pending checkpoint writers before invoking this.
public enum CampaignProgress {
    public static func reset(in defaults: UserDefaults) {
        let keys: Set<String> = ["orbit.current", "orbit.unlocked", "orbit.checkpoint.v1",
            "orbit.checkpoint.recovery.v1", "orbit.checkpoint.catalogRecovery.v1",
            "orbit.lastVictory.v1", "orbit.finalePresented.v1"]
        let prefixes = ["orbit.best.holes.", "orbit.best.matter.", "orbit.lastOutcome."]
        for key in defaults.dictionaryRepresentation().keys
            where keys.contains(key) || prefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
        }
        defaults.set(0, forKey: "orbit.current")
        defaults.set(0, forKey: "orbit.unlocked")
    }
}
