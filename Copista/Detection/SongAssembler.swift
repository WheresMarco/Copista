import Foundation

/// Turns each document's per-page classification into `Part`s for a song: consecutive pages
/// with the same kind become one part, every document's score pages merge into a single score
/// part, and — the safety net — if two parts in the same song ever claim the same instrument,
/// the second becomes a visible *variant* rather than silently overwriting the first.
nonisolated enum SongAssembler {

    struct DocumentPages: Sendable {
        let documentID: UUID
        let results: [CachedPageResult]
    }

    static func assemble(songTitle: String, documents: [DocumentPages]) -> (parts: [Part], issues: [SongIssue]) {
        var rawParts: [Part] = []
        var blankPages: [PageItem] = []
        var editedPositions: [UUID: Int] = [:]

        for doc in documents {
            var currentKind: PartKind?
            var currentExtras: [UUID] = []
            var currentPages: [PageItem] = []
            var pendingBlanks: [PageItem] = []

            func flush() {
                guard let kind = currentKind, !currentPages.isEmpty else { return }
                rawParts.append(Part(id: UUID(), songTitle: songTitle, kind: kind, extraInstruments: currentExtras, pages: currentPages))
            }

            for result in doc.results.sorted(by: { $0.pageIndex < $1.pageIndex }) {
                let item = PageItem(
                    id: UUID(), documentID: doc.documentID, pageIndex: result.pageIndex,
                    rotation: result.rotation, cropRect: result.cropRect,
                    detectedText: result.detectedText, confidence: result.confidence, source: result.source
                )
                if let position = result.partPosition { editedPositions[item.id] = position }
                if case .blank = result.kind {
                    // Excluded by hand: stays out. Detected blank: left pending, because if the
                    // same part carries on after it, it's a deliberate page-turn gap.
                    if result.source == .manual { blankPages.append(item) } else { pendingBlanks.append(item) }
                } else if let currentKind, currentKind == result.kind {
                    currentPages += pendingBlanks + [item]
                    pendingBlanks = []
                } else {
                    flush()
                    blankPages += pendingBlanks
                    pendingBlanks = []
                    currentKind = result.kind
                    currentExtras = result.extraInstruments
                    currentPages = [item]
                }
            }
            flush()
            blankPages += pendingBlanks
        }

        // Every document's score pages merge into a single score part, at the front.
        var parts = rawParts.filter { !isScore($0) }
        let scorePages = rawParts.filter(isScore).flatMap(\.pages)
        if !scorePages.isEmpty {
            parts.insert(Part(id: UUID(), songTitle: songTitle, kind: .score, extraInstruments: [], pages: scorePages), at: 0)
        }

        // Duplicate-instrument safety net: the second occupant of a slot becomes a variant,
        // not a silent overwrite.
        var seen: Set<UUID> = []
        var finalParts = parts.map { part -> Part in
            guard case .instrument(let id) = part.kind else { return part }
            if seen.contains(id) {
                return Part(id: part.id, songTitle: part.songTitle, kind: part.kind, extraInstruments: part.extraInstruments, pages: part.pages, variantLabel: part.pages.first?.detectedText)
            }
            seen.insert(id)
            return part
        }

        if !blankPages.isEmpty {
            finalParts.append(Part(id: UUID(), songTitle: songTitle, kind: .blank, pages: blankPages))
        }
        // Parts form in file order; only then can the order the user gave their pages be restored.
        if !editedPositions.isEmpty {
            for index in finalParts.indices {
                finalParts[index].pages = finalParts[index].pages.enumerated().sorted { a, b in
                    let aPosition = editedPositions[a.element.id] ?? .max, bPosition = editedPositions[b.element.id] ?? .max
                    return aPosition == bPosition ? a.offset < b.offset : aPosition < bPosition
                }.map(\.element)
            }
        }
        return (finalParts, issues(for: finalParts))
    }

    /// What's worth telling the user about a song's parts, derived fresh so it stays true after edits.
    static func issues(for parts: [Part]) -> [SongIssue] {
        var issues: [SongIssue] = []
        var seen: Set<UUID> = []
        for part in parts {
            switch part.kind {
            case .score:
                issues.append(.includesScore(pageCount: part.pages.count))
            case .unassigned:
                issues += part.pages.map { .unknownName(pageItemID: $0.id, text: $0.detectedText ?? "") }
            case .instrument(let id):
                if !seen.insert(id).inserted, part.needsDuplicateReview { issues.append(.duplicateInstrument(instrumentID: id)) }
                issues += part.pages.filter(\.isUncertain).map { .lowConfidence(pageItemID: $0.id) }
            case .blank:
                break
            }
        }
        return issues
    }

    private static func isScore(_ part: Part) -> Bool {
        if case .score = part.kind { return true }
        return false
    }
}
