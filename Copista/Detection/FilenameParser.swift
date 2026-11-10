import Foundation

/// Breaks a PDF's filename stem into the pieces `NameMatcher` and `SongGrouper` need: the part
/// name (after the last " - "), any clef/key qualifier sitting on the *other* side of the dash
/// ("Olympic g-klav - Euphonium" needs "g-klav" to resolve the euphonium's clef), and whether the
/// stem is a structural marker (score / duplicate set / "parts") rather than an instrument name.
nonisolated enum FilenameParser {

    struct Parsed: Sendable, Hashable {
        var head: String
        var tail: String
        /// The text to hand to NameMatcher: the tail, plus any qualifier found on the head side.
        var matchText: String
        var isScoreMarker: Bool
        var isSetMarker: Bool
        var isPartsMarker: Bool
    }

    private static let scoreMarkers: Set<String> = [
        "score", "full score", "partitur", "particell", "dirigent", "conductor", "direktion", "dirigentstämma"
    ]
    private static let setMarkers: Set<String> = [
        "set", "complete", "komplett", "partitur och stämmor", "hel kår", "alla stämmor"
    ]
    private static let partsMarkers: Set<String> = ["parts", "stämmor", "lättlästa stämmor"]

    private static let qualifiers: [String] = [
        "g-klav", "treble clef", "bass clef", "diskantklav", "basklav", "in bb", "in eb", "i c", "solo"
    ]

    static func stripExtension(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension
    }

    /// Strips a leading ordering index like "178_" or "8_" or "00 " from a filename stem.
    static func stripLeadingIndex(_ stem: String) -> String {
        stem.replacingOccurrences(of: #"^\s*\d{1,4}[_\-.\s]+"#, with: "", options: .regularExpression)
    }

    /// Strips an embedded two-digit ordering index ("Eagle Squadron ALFORD 12 hrn3-4" -> "Eagle
    /// Squadron ALFORD hrn3-4") from every stem in a folder, but only when at least 60% of the
    /// stems in the batch carry the same pattern — otherwise a genuine part number like "Klar 2"
    /// or "hrn3-4" would be stripped as if it were an index.
    static func stripEmbeddedTwoDigitIndices(in stems: [String]) -> [String] {
        let pattern = #"(?<=\s)\d{2}(?=\s)"#
        let hits = stems.filter { $0.range(of: pattern, options: .regularExpression) != nil }
        guard stems.count > 0, Double(hits.count) / Double(stems.count) >= 0.6 else { return stems }
        return stems.map { $0.replacingOccurrences(of: pattern, with: "", options: .regularExpression) }
    }

    /// Whether a short piece of text read off a page labels it as the score. Long text is ruled
    /// out so a title like "The Conductor's March" doesn't turn every part into a score.
    static func isScoreLabel(_ text: String) -> Bool {
        let normalized = TextNormalizer.normalize(text)
        guard normalized.split(separator: " ").count <= 2 else { return false }
        return scoreMarkers.contains { containsWholeWord(normalized, phrase: $0) }
    }

    static func parse(_ stem: String) -> Parsed {
        let (head, tail) = splitAtLastDash(stem)

        let normalizedHead = TextNormalizer.normalize(head)
        let normalizedTail = TextNormalizer.normalize(tail)
        let combined = normalizedHead + " " + normalizedTail

        var matchText = tail
        for qualifier in qualifiers {
            let normalizedQualifier = TextNormalizer.normalize(qualifier)
            guard !normalizedHead.isEmpty, containsWholeWord(normalizedHead, phrase: normalizedQualifier) else { continue }
            guard !containsWholeWord(normalizedTail, phrase: normalizedQualifier) else { continue }
            matchText += " " + qualifier
        }

        return Parsed(
            head: head,
            tail: tail,
            matchText: matchText,
            isScoreMarker: scoreMarkers.contains { containsWholeWord(combined, phrase: $0) },
            isSetMarker: setMarkers.contains { containsWholeWord(combined, phrase: $0) },
            isPartsMarker: partsMarkers.contains { containsWholeWord(combined, phrase: $0) }
        )
    }

    private static func splitAtLastDash(_ stem: String) -> (head: String, tail: String) {
        for separator in [" – ", " - "] {
            if let range = stem.range(of: separator, options: .backwards) {
                let head = String(stem[stem.startIndex..<range.lowerBound])
                let tail = String(stem[range.upperBound...])
                return (head, tail)
            }
        }
        return ("", stem)
    }

    private static func containsWholeWord(_ text: String, phrase: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        var searchStart = text.startIndex
        while let range = text.range(of: phrase, range: searchStart..<text.endIndex) {
            let leftOK = range.lowerBound == text.startIndex || text[text.index(before: range.lowerBound)] == " "
            let rightOK = range.upperBound == text.endIndex || text[range.upperBound] == " "
            if leftOK && rightOK { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }
}
