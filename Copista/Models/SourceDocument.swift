import Foundation

nonisolated enum DocumentRole: Codable, Hashable, Sendable {
    case parts
    case score
    /// A redundant "everything combined" export (e.g. Olympic_Set.pdf) alongside per-instrument
    /// files for the same song. Excluded from analysis by default; the user can include it.
    case duplicateSet
}

nonisolated struct SourceDocument: Identifiable, Hashable, Sendable {
    let id: UUID
    var url: URL
    var bookmarkData: Data?      // security-scoped bookmark, so re-analysis survives relaunch
    var songTitle: String
    var pageCount: Int
    var sha256: String?
    var role: DocumentRole
    var isExcluded: Bool
}
