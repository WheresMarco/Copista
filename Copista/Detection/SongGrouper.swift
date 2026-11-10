import Foundation

nonisolated enum SongLayout: Sendable, Equatable {
    case folderIsSong
    case fileIsSong
}

nonisolated struct DocumentDraft: Sendable, Identifiable, Hashable {
    let id: UUID
    var url: URL
    var role: DocumentRole
}

nonisolated struct SongDraft: Sendable, Identifiable {
    let id: UUID
    var title: String
    var documents: [DocumentDraft]
    var layout: SongLayout
}

/// Groups a flat list of imported PDFs into songs.
///
/// The spec's simple rule — "song title = parent folder name when importing a folder" — breaks
/// as soon as one folder holds several unrelated songs (a real library folder had 24 of them).
/// Instead: bucket by parent directory, then decide per bucket whether the *folder* is one song
/// (most filenames in it name an instrument, or carry a score/set/parts marker) or whether *each
/// file* is its own song (bucket looks like a pile of unrelated single-song PDFs) — in which case
/// files that reduce to the same title after cleanup (e.g. "Valborg - Full Score" and
/// "Valborg - Parts") still merge into one song.
nonisolated struct SongGrouper: Sendable {
    let matcher: NameMatcher

    func group(urls: [URL]) -> [SongDraft] {
        let buckets = Dictionary(grouping: urls) { $0.deletingLastPathComponent() }
        return buckets
            .sorted { $0.key.path.localizedStandardCompare($1.key.path) == .orderedAscending }
            .flatMap { directory, bucketURLs in groupBucket(directory: directory, urls: bucketURLs) }
    }

    /// Several files added together are one song, however little their names have in common.
    func groupAsOneSong(urls: [URL]) -> SongDraft {
        let entries = makeEntries(urls)
        let documents = entries.map { DocumentDraft(id: UUID(), url: $0.url, role: role(for: $0, siblingCount: entries.count)) }
        return SongDraft(id: UUID(), title: sharedTitle(entries), documents: documents, layout: .folderIsSong)
    }

    /// What the files' names have in common ("Olympic" from "Olympic - Horn 1", "Olympic_Set"),
    /// or else the folder they're in. A shared instrument name ("Klarinett 1", "Klarinett 2")
    /// says nothing about the song, so that's not used.
    private func sharedTitle(_ entries: [Entry]) -> String {
        let stems = entries.map { $0.stem.replacingOccurrences(of: "_", with: " ") }
        if var prefix = dominantWordPrefix(stems) {
            for separator in [" - ", " – "] {
                if let range = prefix.range(of: separator) { prefix = String(prefix[..<range.lowerBound]) }
            }
            var words = prefix.split(separator: " ").map(String.init)
            while let last = words.last, !last.contains(where: { $0.isLetter || $0.isNumber }) || matcher.match(words.joined(separator: " ")) != nil {
                words.removeLast()
            }
            let title = cleanTitle(words.joined(separator: " "))
            if !title.isEmpty { return title }
        }
        return cleanTitle(entries.first?.url.deletingLastPathComponent().lastPathComponent ?? "")
    }

    private struct Entry {
        let url: URL
        let stem: String              // leading/embedded indices already stripped
        let parsed: FilenameParser.Parsed
        let isHit: Bool
    }

    private func makeEntries(_ urls: [URL]) -> [Entry] {
        let rawStems = urls.map { FilenameParser.stripExtension($0.lastPathComponent) }
        let deIndexed = FilenameParser.stripEmbeddedTwoDigitIndices(in: rawStems)

        return zip(urls, deIndexed).map { url, stem in
            let cleaned = FilenameParser.stripLeadingIndex(stem)
            let parsed = FilenameParser.parse(cleaned)
            let match = matcher.match(parsed.matchText)
            let isHit = (match?.confidence ?? 0) >= 0.8 || parsed.isScoreMarker || parsed.isSetMarker || parsed.isPartsMarker
            return Entry(url: url, stem: cleaned, parsed: parsed, isHit: isHit)
        }
    }

    private func groupBucket(directory: URL, urls: [URL]) -> [SongDraft] {
        let entries = makeEntries(urls)
        guard !entries.isEmpty else { return [] }

        let hitRate = Double(entries.filter(\.isHit).count) / Double(entries.count)
        if hitRate >= 0.5, entries.count >= 3 {
            return [folderIsSongDraft(directory: directory, entries: entries)]
        }
        return fileIsSongDrafts(entries: entries)
    }

    // MARK: - Layout A: the folder is one song

    private func folderIsSongDraft(directory: URL, entries: [Entry]) -> SongDraft {
        let folderTitle = cleanTitle(directory.lastPathComponent)
        let title: String
        if let prefix = dominantWordPrefix(entries.map(\.stem)) {
            let squashedFolder = squash(folderTitle)
            let squashedPrefix = squash(prefix)
            // The prefix only ever *trims* an over-long folder name (e.g. a folder that also
            // names an arrangement/venue); it never introduces a longer or unrelated title.
            title = (squashedFolder.contains(squashedPrefix) && squashedFolder != squashedPrefix) ? prefix : folderTitle
        } else {
            title = folderTitle
        }

        let documents = entries.map { DocumentDraft(id: UUID(), url: $0.url, role: role(for: $0, siblingCount: entries.count)) }
        return SongDraft(id: UUID(), title: title, documents: documents, layout: .folderIsSong)
    }

    /// The longest leading run of words shared by at least 60% of the stems (capped at 4 words),
    /// requiring at least one more word after it — so it never swallows an entire short filename.
    private func dominantWordPrefix(_ stems: [String]) -> String? {
        let wordLists = stems.map { $0.split(separator: " ").map(String.init) }
        guard let maxLength = wordLists.map(\.count).max(), maxLength > 1 else { return nil }

        var best: String?
        for length in 1...min(4, maxLength - 1) {
            var counts: [String: (display: String, count: Int)] = [:]
            for words in wordLists where words.count > length {
                let prefix = words.prefix(length).joined(separator: " ")
                let key = squash(prefix)
                counts[key, default: (prefix, 0)].count += 1
            }
            guard let winner = counts.values.max(by: { $0.count < $1.count }) else { continue }
            if Double(winner.count) / Double(stems.count) >= 0.6 {
                best = winner.display
            }
        }
        return best
    }

    // MARK: - Layout B: each file is its own song, merging equal titles

    private func fileIsSongDrafts(entries: [Entry]) -> [SongDraft] {
        var order: [String] = []
        var titlesByKey: [String: String] = [:]
        var urlsByKey: [String: [URL]] = [:]

        for entry in entries {
            let title = cleanTitle(entry.stem)
            let key = squash(title)
            if urlsByKey[key] == nil {
                order.append(key)
                titlesByKey[key] = title
            }
            urlsByKey[key, default: []].append(entry.url)
        }

        return order.map { key in
            let urls = urlsByKey[key] ?? []
            let documents = urls.map { url -> DocumentDraft in
                let entry = entries.first { $0.url == url }!
                return DocumentDraft(id: UUID(), url: url, role: role(for: entry, siblingCount: urls.count))
            }
            return SongDraft(id: UUID(), title: titlesByKey[key] ?? "", documents: documents, layout: .fileIsSong)
        }
    }

    // MARK: - Shared helpers

    private func role(for entry: Entry, siblingCount: Int) -> DocumentRole {
        // A document that signals score+parts together (e.g. "Partitur och stämmor") is a mixed
        // document, not a pure score — leave it to DocumentAnalyzer to sort out page by page.
        if entry.parsed.isScoreMarker, !entry.parsed.isSetMarker, !entry.parsed.isPartsMarker {
            return .score
        }
        if siblingCount >= 2, entry.parsed.isSetMarker {
            return .duplicateSet
        }
        return .parts
    }

    private static let trailingMarkers = [
        "- Full Score", "- Partitur och stämmor", "- Parts", "- Set", "- Score",
        " Full Score", " Partitur och stämmor", " Parts", " Set", " Score",
    ]

    private func cleanTitle(_ text: String) -> String {
        var title = FilenameParser.stripLeadingIndex(text.replacingOccurrences(of: "_", with: " "))
        for marker in Self.trailingMarkers {
            if let range = title.range(of: marker, options: [.caseInsensitive, .backwards]), range.upperBound == title.endIndex {
                title.removeSubrange(range)
            }
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    private func squash(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
