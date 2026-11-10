import Foundation

/// Something the user should know before committing paper to a print job.
nonisolated struct PrintCheck: Identifiable, Hashable, Sendable {
    let severity: ReviewItem.Severity
    let message: String
    /// The song to open in Review to deal with it, when it's something Review can deal with.
    var songID: UUID?
    var id: String { message }
}

/// The preflight list on the Print step: pages that won't print, parts nobody gets, and anything
/// else that would otherwise only be discovered at the copier.
nonisolated enum PrintChecks {

    static func run(songs: [Song], skippedFileNames: [UUID: String], instruments: [Instrument], job: PrintJob, combinedPartsUsesSum: Bool) -> [PrintCheck] {
        var checks: [PrintCheck] = []
        let names = Dictionary(instruments.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })

        for song in songs {
            var unknownCount = 0, uncertainCount = 0
            let unfamiliarCount = song.reviewItems.first { $0.kind == .unknownLabel }?.pageIDs.count ?? 0
            var duplicated: [UUID] = []
            for issue in song.issues {
                switch issue {
                case .unknownName: unknownCount += 1
                case .lowConfidence: uncertainCount += 1
                case .duplicateInstrument(let id): duplicated.append(id)
                case .duplicateSet(let documentID):
                    if let file = skippedFileNames[documentID] {
                        checks.append(PrintCheck(severity: .note, message: String(localized: "“\(file)” was skipped because “\(song.title)” also has the same parts as separate files.")))
                    }
                case .includesScore:
                    break
                }
            }
            if unknownCount > 0 {
                checks.append(PrintCheck(severity: .mustFix, message: String(localized: "“\(song.title)”: pages with no instrument won't print (\(unknownCount))."), songID: song.id))
            }
            if uncertainCount > 0 {
                checks.append(PrintCheck(severity: .check, message: String(localized: "“\(song.title)”: pages that were hard to read. Check their instruments in Review (\(uncertainCount))."), songID: song.id))
            }
            if unfamiliarCount > 0 {
                checks.append(PrintCheck(severity: .note, message: String(localized: "“\(song.title)”: pages with unfamiliar words at the top, kept with the part before them (\(unfamiliarCount))."), songID: song.id))
            }
            for id in duplicated {
                let name = names[id] ?? String(localized: "Unknown instrument")
                checks.append(PrintCheck(severity: .check, message: String(localized: "“\(song.title)” has more than one part for \(name). All of them will print."), songID: song.id))
            }
            for part in song.parts where OutputPlanner.copyCount(for: part, job: job, combinedPartsUsesSum: combinedPartsUsesSum) == 0 {
                guard case .instrument(let id) = part.kind else { continue }
                let name = names[id] ?? String(localized: "Unknown instrument")
                checks.append(PrintCheck(severity: .note, message: String(localized: "\(name) in “\(song.title)” is set to 0 copies and won't print.")))
            }
            if song.scorePart != nil, !song.includeScore {
                checks.append(PrintCheck(severity: .note, message: String(localized: "The score of “\(song.title)” isn't included.")))
            }
        }
        return checks
    }
}
