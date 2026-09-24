import Foundation

enum SortMode: String, Codable, CaseIterable {
    case byInstrument
    case bySong
    case separateFiles
}

struct PrintJob: Codable {
    var copies: [UUID: Int]     // instrument id -> copy count for this job
    var includeScore: Bool
    var scoreCopies: Int
    var sortMode: SortMode
    var songTitles: [String]    // song list, in the order they should be printed
}
