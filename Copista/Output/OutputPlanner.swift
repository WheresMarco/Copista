import Foundation
import CoreGraphics

/// One source page (or half-page) to draw onto the output PDF, or a blank page when `documentURL`
/// is nil.
nonisolated struct SheetSpec: Sendable {
    var documentURL: URL?
    var pageIndex: Int
    var rotation: Int
    var cropRect: CGRect?

    static let blank = SheetSpec(documentURL: nil, pageIndex: 0, rotation: 0, cropRect: nil)
}

nonisolated struct SongOutput: Sendable {
    let song: Song
    let plan: OutputPlan
}

nonisolated struct OutputPlan: Sendable {
    var sheets: [SheetSpec]

    /// Pages of actual music, leaving out blank backs added for double-sided printing.
    var musicPageCount: Int {
        sheets.filter { $0.documentURL != nil }.count
    }

    func paperCount(isDoubleSided: Bool) -> Int {
        isDoubleSided ? (sheets.count + 1) / 2 : sheets.count
    }
}

/// Turns a song into a flat, ordered list of sheets to draw: its score, then each instrument's
/// parts in score order, copies grouped consecutively. Every song is a PDF of its own: songs are
/// handed out, filed and reprinted one at a time, so they're never mixed into one file.
nonisolated enum OutputPlanner {

    static func plan(for song: Song, documentURLs: [UUID: URL], instruments: [Instrument], job: PrintJob, combinedPartsUsesSum: Bool) -> OutputPlan {
        var sheets = scoreSheets(of: song, documentURLs: documentURLs, job: job)
        for instrument in instruments.sorted(by: { $0.sortIndex < $1.sortIndex }) {
            sheets += partSheets(of: song, instrument: instrument.id, documentURLs: documentURLs, job: job, combinedPartsUsesSum: combinedPartsUsesSum)
        }
        return OutputPlan(sheets: sheets)
    }

    private static func scoreSheets(of song: Song, documentURLs: [UUID: URL], job: PrintJob) -> [SheetSpec] {
        guard song.includeScore, let score = song.scorePart else { return [] }
        return repeated(part: score, copies: job.scoreCopies, documentURLs: documentURLs, isDoubleSided: job.isDoubleSided)
    }

    /// Every part the instrument has in this song. A song can hold more than one — a flagged
    /// variant, or a part split up by a misread page — and leaving any out loses music silently.
    private static func partSheets(of song: Song, instrument id: UUID, documentURLs: [UUID: URL], job: PrintJob, combinedPartsUsesSum: Bool) -> [SheetSpec] {
        song.parts.filter { partMatches($0, instrument: id) }.flatMap { part in
            repeated(part: part, copies: copyCount(for: part, job: job, combinedPartsUsesSum: combinedPartsUsesSum), documentURLs: documentURLs, isDoubleSided: job.isDoubleSided)
        }
    }

    private static func partMatches(_ part: Part, instrument id: UUID) -> Bool {
        part.kind == .instrument(id)
    }

    static func copyCount(for part: Part, job: PrintJob, combinedPartsUsesSum: Bool) -> Int {
        guard case .instrument(let primary) = part.kind else { return 0 }
        let counts = ([primary] + part.extraInstruments).map { job.copies[$0] ?? 0 }
        return combinedPartsUsesSum ? counts.reduce(0, +) : (counts.max() ?? 0)
    }

    private static func repeated(part: Part, copies: Int, documentURLs: [UUID: URL], isDoubleSided: Bool) -> [SheetSpec] {
        guard copies > 0 else { return [] }
        var specs = part.pages.compactMap { page -> SheetSpec? in
            guard let url = documentURLs[page.documentID] else { return nil }
            return SheetSpec(documentURL: url, pageIndex: page.pageIndex, rotation: page.rotation, cropRect: page.cropRect)
        }
        // An odd-length copy gets a blank back, or the next copy would start on it.
        if isDoubleSided, specs.count % 2 == 1 { specs.append(.blank) }
        return Array(repeating: specs, count: copies).flatMap { $0 }
    }
}
