import Foundation

/// One thing in a song that a person should look at, and the pages it concerns.
nonisolated struct ReviewItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Won't print until it has an instrument.
        case noInstrument
        /// A name was read, but barely: the instrument is a guess.
        case hardToRead
        /// A later part for an instrument that already has one. All of them print.
        case duplicatePart(instrumentID: UUID)
        /// Kept with the part before, but with words where a name would go that weren't one Copista
        /// knows. Those may be a new part's name. A page with nothing there is simply the next page.
        case unknownLabel
    }

    enum Severity: Sendable {
        case mustFix, check, note
    }

    let kind: Kind
    let pageIDs: [UUID]

    var id: Kind { kind }

    var severity: Severity {
        switch kind {
        case .noInstrument: .mustFix
        case .hardToRead, .duplicatePart: .check
        case .unknownLabel: .note
        }
    }
}

extension Song {
    /// Most urgent first. Derived from the parts, so it's always true of the song as it is now.
    nonisolated var reviewItems: [ReviewItem] {
        var noInstrument: [UUID] = []
        var hardToRead: [UUID] = []
        var unknownLabel: [UUID] = []
        var duplicates: [ReviewItem] = []
        var seen: Set<UUID> = []

        for part in parts {
            switch part.kind {
            case .unassigned:
                noInstrument += part.pages.map(\.id)
            case .instrument(let id):
                hardToRead += part.pages.filter(\.isUncertain).map(\.id)
                unknownLabel += part.pages.filter { $0.source == .continuation && $0.detectedText?.isEmpty == false }.map(\.id)
                if !seen.insert(id).inserted, part.needsDuplicateReview {
                    duplicates.append(ReviewItem(kind: .duplicatePart(instrumentID: id), pageIDs: part.pages.map(\.id)))
                }
            case .score, .blank:
                break
            }
        }

        var items: [ReviewItem] = []
        if !noInstrument.isEmpty { items.append(ReviewItem(kind: .noInstrument, pageIDs: noInstrument)) }
        if !hardToRead.isEmpty { items.append(ReviewItem(kind: .hardToRead, pageIDs: hardToRead)) }
        items += duplicates
        if !unknownLabel.isEmpty { items.append(ReviewItem(kind: .unknownLabel, pageIDs: unknownLabel)) }
        return items
    }

    /// The pages that follow these in their files and only belong where they are because of the
    /// page before them: everything up to the next page with a name of its own. Pages that are
    /// left out of the print don't end the run, and don't join it.
    nonisolated func pagesCarried(by pageIDs: [UUID]) -> [UUID] {
        let starts = Set(pageIDs)
        let leftOut = Set(parts.filter { $0.kind == .blank }.flatMap(\.pages).map(\.id))
        let pages = parts.flatMap(\.pages)
        var carried: [UUID] = []
        for documentID in documentIDs {
            var isCarrying = false
            for page in pages.filter({ $0.documentID == documentID }).sorted(by: { $0.pageIndex < $1.pageIndex }) {
                if starts.contains(page.id) {
                    isCarrying = true
                } else if isCarrying, !leftOut.contains(page.id) {
                    if page.source == .continuation { carried.append(page.id) } else { isCarrying = false }
                }
            }
        }
        return carried
    }

    /// How many pages won't print until someone gives them an instrument.
    nonisolated var mustFixCount: Int {
        reviewItems.filter { $0.severity == .mustFix }.reduce(0) { $0 + $1.pageIDs.count }
    }

    /// How many things will print, but might be wrong.
    nonisolated var checkCount: Int {
        reviewItems.filter { $0.severity == .check }.reduce(0) { total, item in
            if case .duplicatePart = item.kind { return total + 1 }
            return total + item.pageIDs.count
        }
    }

    /// The song's parts in the order they're shown: anything without an instrument first, since
    /// that's what needs doing, then the score, then the instruments in score order, section by
    /// section, and pages that won't print last.
    nonisolated func partGroups(instruments: [Instrument]) -> [PartGroup] {
        let byID = Dictionary(instruments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func instrument(of part: Part) -> Instrument? {
            if case .instrument(let id) = part.kind { return byID[id] }
            return nil
        }

        var groups: [PartGroup] = []
        func appendGroup(_ kind: PartGroup.Kind, where matches: (Part) -> Bool) {
            let members = parts.filter(matches)
            if !members.isEmpty { groups.append(PartGroup(kind: kind, parts: members)) }
        }

        appendGroup(.unassigned) { $0.kind == .unassigned }
        appendGroup(.score) { $0.kind == .score }
        for section in InstrumentSection.allCases {
            let members = parts
                .filter {
                    guard case .instrument = $0.kind else { return false }
                    // A part naming an instrument since removed from the catalog still has to show.
                    return (instrument(of: $0)?.section ?? .other) == section
                }
                .enumerated()
                .sorted { a, b in
                    let aIndex = instrument(of: a.element)?.sortIndex ?? .max
                    let bIndex = instrument(of: b.element)?.sortIndex ?? .max
                    return aIndex == bIndex ? a.offset < b.offset : aIndex < bIndex
                }
                .map(\.element)
            if !members.isEmpty { groups.append(PartGroup(kind: .section(section), parts: members)) }
        }
        appendGroup(.blank) { $0.kind == .blank }
        return groups
    }
}

extension Part {
    /// A later part for the same instrument stops being a question once all of it has been
    /// looked at and kept.
    nonisolated var needsDuplicateReview: Bool {
        pages.contains { $0.source != .manual }
    }
}

nonisolated struct PartGroup: Identifiable, Sendable {
    enum Kind: Hashable, Sendable {
        case unassigned, score, section(InstrumentSection), blank
    }

    let kind: Kind
    let parts: [Part]

    var id: Kind { kind }
}
