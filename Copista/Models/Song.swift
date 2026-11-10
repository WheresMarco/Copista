import Foundation

nonisolated enum SongIssue: Hashable, Sendable {
    case unknownName(pageItemID: UUID, text: String)
    case lowConfidence(pageItemID: UUID)
    case duplicateInstrument(instrumentID: UUID)
    case duplicateSet(documentID: UUID)
    case includesScore(pageCount: Int)
}

nonisolated struct Song: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var documentIDs: [UUID]
    var parts: [Part]
    var issues: [SongIssue]
    var includeScore: Bool

    /// "5 parts · 30 pages", for wherever a song is listed. Blank and excluded pages don't count.
    var summary: String {
        let partCount = parts.filter { if case .instrument = $0.kind { return true }; return false }.count
        let pageCount = parts.filter { $0.kind != .blank }.reduce(0) { $0 + $1.pages.count }
        return String(localized: "\(partCount) parts") + " · " + String(localized: "\(pageCount) pages")
    }

    var scorePart: Part? {
        parts.first { $0.kind == .score }
    }
}
