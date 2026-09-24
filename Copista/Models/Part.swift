import Foundation

enum PartKind: Codable, Hashable {
    case instrument(UUID)
    case score
    case unassigned
    case blank
}

struct Part: Identifiable {
    let id: UUID
    var songTitle: String
    var kind: PartKind
    var extraInstruments: [UUID]      // combined parts like "Horn 1/3" → also serves Horn 3
    var pages: [PageItem]
}
