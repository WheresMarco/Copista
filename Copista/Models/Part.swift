import Foundation

nonisolated enum PartKind: Codable, Hashable, Sendable {
    case instrument(UUID)
    case score
    case unassigned
    case blank
}

nonisolated struct Part: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    var songTitle: String
    var kind: PartKind
    var extraInstruments: [UUID]      // combined parts like "Horn 1/3" → also serves Horn 3
    var pages: [PageItem]
    /// When a second, unrelated part is detected for an instrument slot already taken in this
    /// song, it becomes a variant instead of silently overwriting the first — this label holds
    /// its raw detected text so both stay visible in Review with a duplicate-instrument issue.
    var variantLabel: String?

    init(id: UUID, songTitle: String, kind: PartKind, extraInstruments: [UUID] = [], pages: [PageItem], variantLabel: String? = nil) {
        self.id = id
        self.songTitle = songTitle
        self.kind = kind
        self.extraInstruments = extraInstruments
        self.pages = pages
        self.variantLabel = variantLabel
    }
}
