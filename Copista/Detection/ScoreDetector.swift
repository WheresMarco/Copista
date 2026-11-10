import Foundation

/// A page carrying five or more distinct instrument names is a full-score page, not a single
/// part — e.g. a page listing Picc, Fl 1/2, Ob 1, Kl 1, Kl 2 all at once.
nonisolated enum ScoreDetector {
    static let minimumDistinctInstruments = 5

    static func isScorePage(matches: [NameMatch]) -> Bool {
        var distinct = Set<UUID>()
        for match in matches {
            distinct.insert(match.primary)
            distinct.formUnion(match.extras)
        }
        return distinct.count >= minimumDistinctInstruments
    }
}
