import Foundation

nonisolated struct PrintJob: Codable, Sendable {
    var copies: [UUID: Int]     // instrument id -> copy count for this job
    var scoreCopies: Int
    var isDoubleSided: Bool     // each copy of a part must start on the front of a sheet
}
