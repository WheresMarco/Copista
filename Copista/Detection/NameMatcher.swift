import Foundation

/// Matches a piece of detected text (a filename, an OCR line, a page's top-region text) against
/// the instrument catalog.
///
/// Match order: a hard-coded pair of combined-instrument idioms that generic parsing can't
/// reconstruct → an explicit combined-number pattern (`1/3`, `1-2`, `1&2`, `1, 3`) → exact alias
/// → longest whole-word alias substring → a bare, unnumbered abbreviation resolved against a
/// numbered family ("fl" → Flute 1+2) → fuzzy (Levenshtein ratio ≥ 0.85). Whichever stage wins,
/// a number found in the text must agree with the matched instrument's own number — "klarinett 2"
/// must never resolve to Clarinet 1 — and any leftover text is given one more pass to pick up a
/// second, combined instrument (`baskl (fg2)` → Bass Clarinet + Bassoon 2).
nonisolated struct NameMatcher: Sendable {

    private struct Entry: Sendable {
        let alias: String          // normalized
        let instrument: Instrument
    }

    private let entries: [Entry]                        // longest alias first
    private let familyMembers: [String: [Instrument]]    // family key -> members, sorted by number
    private let bareRoots: [String: String]              // normalized root -> family key
    private let nameWords: Set<String>                   // every word in any alias

    init(instruments: [Instrument]) {
        var entries: [Entry] = []
        var families: [String: [Instrument]] = [:]
        var roots: [String: String] = [:]
        var nameWords: Set<String> = []

        for instrument in instruments {
            for alias in instrument.namesToRecognize {
                let normalized = TextNormalizer.normalize(alias)
                guard !normalized.isEmpty else { continue }
                entries.append(Entry(alias: normalized, instrument: instrument))
                nameWords.formUnion(normalized.split(separator: " ").map(String.init))

                if instrument.number != nil, let family = instrument.family {
                    var words = normalized.split(separator: " ").map(String.init)
                    if let last = words.last, Int(last) != nil {
                        words.removeLast()
                        let root = words.joined(separator: " ")
                        if !root.isEmpty { roots[root] = family }
                    }
                }
            }
            if let family = instrument.family {
                families[family, default: []].append(instrument)
            }
        }
        for key in families.keys {
            families[key]?.sort { ($0.number ?? 0) < ($1.number ?? 0) }
        }

        self.entries = entries.sorted { $0.alias.count > $1.alias.count }
        self.familyMembers = families
        self.bareRoots = roots
        self.nameWords = nameWords
    }

    func match(_ rawText: String) -> NameMatch? {
        matchAllowingCombine(rawText, allowSecondaryPass: true)
    }

    /// Whether a line is an instrument's name and nothing more, give or take a number or key
    /// ("Eb Clarinet", "TRUMPET I", "Piccolo (Ad lib.)"), rather than a longer phrase that has an
    /// instrument in it, like the title "Trumpet Voluntary".
    func isOnlyAName(_ rawText: String) -> Bool {
        let words = TextNormalizer.normalize(TextNormalizer.foldCyrillicLookalikes(rawText)).split(separator: " ").map(String.init)
        return words.contains(where: isNameWord) && words.allSatisfy { isNameWord($0) || $0.count <= 3 }
    }

    /// Long words can be a little off, as OCR and spelling leave them ("Bariton", "Flutes"). Short
    /// ones can't: "Cuba" is one letter from a tuba.
    private func isNameWord(_ word: String) -> Bool {
        nameWords.contains(word) || (word.count >= 6 && nameWords.contains { levenshteinRatio(word, $0) >= 0.75 })
    }

    /// `match`, plus tolerance for how OCR garbles old hand-lettered labels. Anything that needed
    /// repairing comes back with a low confidence, so Review flags it instead of trusting it.
    ///
    /// `allowWordRepair` enables per-word fuzzy matching ("HOEN" → horn). That is loose enough to
    /// turn a title like "Cuba" into a tuba, so callers only allow it where a part name is printed.
    func matchOCR(_ rawText: String, allowWordRepair: Bool = true) -> NameMatch? {
        let text = TextNormalizer.foldCyrillicLookalikes(rawText)
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)

        // Two letters on their own are a marking on the music, not a name: a trill read as "tp"
        // would otherwise be a trumpet part. "Tp 1" still is one.
        if text.filter(\.isLetter).count <= 2, !text.contains(where: \.isNumber) { return nil }

        // The flat sign on a hand-lettered "E♭ Clarinet" is rarely read at all.
        if words.count >= 2, words[0] == "E", let repaired = match("eb " + words.dropFirst().joined(separator: " ")) {
            return capped(repaired, at: 0.7)
        }

        var hasUnresolvedNumber = false
        if words.count >= 2, let number = TextNormalizer.garbledOrdinal(words[0]) {
            let rest = words.dropFirst().joined(separator: " ")
            if let repaired = match("\(rest) \(number)"), resolves(repaired, to: number) {
                return capped(repaired, at: 0.7)
            }
            if allowWordRepair, let root = closestRoot(in: rest), let repaired = match("\(root) \(number)"), resolves(repaired, to: number) {
                return capped(repaired, at: 0.55)
            }
            hasUnresolvedNumber = true
        }

        if let direct = match(text) {
            // An unreadable word in front of a number-less name ("SPA CLARINET") is probably the
            // part's number, which this match has just guessed at.
            let isBareGuess = words.count >= 2 && !words.contains { $0.contains(where: \.isNumber) }
                && instrument(id: direct.primary)?.number != nil && direct.extras.isEmpty
                && TextNormalizer.normalize(rawText).split(separator: " ").count >= 2
                && !aliasesContain(TextNormalizer.normalize(rawText))
            return isBareGuess || hasUnresolvedNumber ? capped(direct, at: 0.55) : direct
        }

        if allowWordRepair, let root = closestRoot(in: text), let repaired = match(root) {
            return capped(repaired, at: 0.55)
        }
        return nil
    }

    private func capped(_ match: NameMatch, at confidence: Double) -> NameMatch {
        var match = match
        match.confidence = min(match.confidence, confidence)
        return match
    }

    private func resolves(_ match: NameMatch, to number: Int) -> Bool {
        instrument(id: match.primary)?.number == number
    }

    private func instrument(id: UUID) -> Instrument? {
        entries.first { $0.instrument.id == id }?.instrument
    }

    private func aliasesContain(_ normalized: String) -> Bool {
        entries.contains { $0.alias == normalized }
    }

    /// The single-word instrument name or family root closest to one of the words in `text`.
    private func closestRoot(in text: String) -> String? {
        let candidates = Set(bareRoots.keys).union(entries.map(\.alias)).filter { !$0.contains(" ") && $0.count >= 4 }
        var best: (root: String, ratio: Double)?
        for word in TextNormalizer.normalize(text).split(separator: " ").map(String.init) where word.count >= 4 {
            for candidate in candidates {
                let ratio = levenshteinRatio(word, candidate)
                if ratio >= 0.75, ratio > (best?.ratio ?? 0) { best = (candidate, ratio) }
            }
        }
        return best?.root
    }

    // MARK: - Stages

    private func matchAllowingCombine(_ rawText: String, allowSecondaryPass: Bool) -> NameMatch? {
        let kept = TextNormalizer.normalizeKeepingSeparators(rawText)
        guard !kept.isEmpty else { return nil }

        if let special = matchSpecialPhrase(kept) { return special }
        if let combo = matchNumericCombo(kept) { return combo }

        let full = TextNormalizer.finish(kept)
        guard !full.isEmpty else { return nil }

        if let hit = matchExactOrSubstring(full) {
            guard allowSecondaryPass else { return hit.match }
            return withSecondaryPass(hit.match, remaining: removingWholeWordSubstring(full, phrase: hit.alias))
        }

        if let match = matchBareFamily(full, depth: 0) {
            return match
        }

        if let match = matchFuzzy(full) {
            return match
        }

        return nil
    }

    /// Two spellings, found in the real library, for "bass drum and cymbals" combined onto one
    /// page — too irregular to reconstruct from the alias table generically.
    private func matchSpecialPhrase(_ kept: String) -> NameMatch? {
        let phrases = ["bas å beck", "bas o beck", "bas och beck", "bas och bäcken"]
        guard phrases.contains(where: { kept.contains($0) }),
              let bassdrum = instrument(forKey: "bassdrum"),
              let cymbals = instrument(forKey: "cymbals")
        else { return nil }
        return NameMatch(primary: bassdrum.id, extras: [cymbals.id], confidence: 0.85)
    }

    /// Finds a run like "1/3", "1-2", "1&2", "1, 3" and resolves the surrounding text (with the
    /// numbers removed) to a family, then maps each number to that family's member.
    private func matchNumericCombo(_ kept: String) -> NameMatch? {
        guard let range = kept.range(of: #"\d{1,2}(?:\s*[/\-&,]\s*\d{1,2})+"#, options: .regularExpression) else {
            return nil
        }
        let numberWords = kept[range].split(whereSeparator: { !$0.isNumber })
        let numbers = numberWords.compactMap { Int($0) }
        guard numbers.count >= 2 else { return nil }

        var remainder = kept
        remainder.removeSubrange(range)
        let base = TextNormalizer.finish(remainder)
        guard let family = familyEatingLeadingNoise(base), let members = familyMembers[family] else { return nil }

        let matched = numbers.compactMap { n in members.first { $0.number == n } }
        guard matched.count >= 2 else { return nil }
        return NameMatch(primary: matched[0].id, extras: matched.dropFirst().map(\.id), confidence: 0.9)
    }

    /// Exact alias match, else the longest alias that appears as a whole-word substring.
    ///
    /// Deliberately does not veto on the text's number here: an alias that carries a number
    /// (e.g. "klar 2") can only ever be found in text that contains that same number, since the
    /// number is part of the alias phrase being searched for — the substring search is
    /// self-consistent by construction. A text-wide number check would instead misfire on
    /// combined text where a *different* instrument's number sits elsewhere in the string (e.g.
    /// "piccola flöjt 2" — the "2" belongs to flute, not to the bare "piccola" match).
    private func matchExactOrSubstring(_ full: String) -> (match: NameMatch, alias: String)? {
        if let exact = entries.first(where: { $0.alias == full }) {
            return (finalize(exact.instrument, confidence: 0.95, aliasHasNumber: hasNumber(exact.alias)), exact.alias)
        }

        for entry in entries {
            guard containsWholeWord(full, phrase: entry.alias) else { continue }
            return (finalize(entry.instrument, confidence: 0.85, aliasHasNumber: hasNumber(entry.alias)), entry.alias)
        }
        return nil
    }

    /// A bare, unnumbered abbreviation ("fl", "altsax", "tuba") resolved against a numbered
    /// family: family of 2 combines both members; family of 3+ resolves to member 1.
    /// Tries the whole phrase, then progressively drops leading words (eats through noise like
    /// "Eagle Squadron ALFORD 12"), then a plural "-s" strip, then a prefix-abbreviation match.
    private func matchBareFamily(_ full: String, depth: Int) -> NameMatch? {
        guard depth < 2 else { return nil }

        if let family = familyEatingLeadingNoise(full), let members = familyMembers[family], !members.isEmpty {
            return combinedBareMatch(members)
        }

        if full.hasSuffix("s"), full.count > 3 {
            let singular = String(full.dropLast())
            if let match = matchBareFamily(singular, depth: depth + 1) { return match }
        }

        return nil
    }

    /// Tries the whole phrase against the bare-root index, then progressively drops leading
    /// words, so noise like "Eagle Squadron ALFORD 12" in front of "hrn" doesn't prevent the
    /// family lookup from reaching "hrn".
    private func familyEatingLeadingNoise(_ full: String) -> String? {
        var words = full.split(separator: " ").map(String.init)
        while !words.isEmpty {
            let candidate = words.joined(separator: " ")
            if let family = resolveFamily(candidate) { return family }
            words.removeFirst()
        }
        return nil
    }

    private func hasNumber(_ alias: String) -> Bool {
        alias.split(separator: " ").contains { Int($0) != nil }
    }

    private func resolveFamily(_ text: String) -> String? {
        if let family = bareRoots[text] { return family }
        // Abbreviation: the text is a short prefix of a known root ("alts" of "altsax").
        guard text.count >= 3 else { return nil }
        // Sorted: a dictionary's order changes from launch to launch, and so would the answer.
        return bareRoots.keys.sorted().first { $0.count > text.count && $0.hasPrefix(text) }.flatMap { bareRoots[$0] }
    }

    private func combinedBareMatch(_ members: [Instrument]) -> NameMatch {
        if members.count == 2 {
            return NameMatch(primary: members[0].id, extras: [members[1].id], confidence: 0.80)
        }
        return NameMatch(primary: members[0].id, extras: [], confidence: 0.75)
    }

    private func matchFuzzy(_ full: String) -> NameMatch? {
        let textNumber = firstNumberToken(full)
        var best: (entry: Entry, ratio: Double)?
        for entry in entries {
            guard agrees(entry.instrument, with: textNumber) else { continue }
            guard abs(entry.alias.count - full.count) <= 4 else { continue }
            let ratio = levenshteinRatio(full, entry.alias)
            guard ratio >= 0.85 else { continue }
            if best == nil || ratio > best!.ratio { best = (entry, ratio) }
        }
        guard let best else { return nil }
        return finalize(best.entry.instrument, confidence: 0.8, aliasHasNumber: hasNumber(best.entry.alias))
    }

    // MARK: - Helpers

    private func finalize(_ instrument: Instrument, confidence: Double, aliasHasNumber: Bool) -> NameMatch {
        guard !aliasHasNumber, let family = instrument.family, let members = familyMembers[family] else {
            return NameMatch(primary: instrument.id, confidence: confidence)
        }
        if members.count == 2 {
            let other = members.first { $0.id != instrument.id }
            return NameMatch(primary: instrument.id, extras: other.map { [$0.id] } ?? [], confidence: min(confidence, 0.80))
        }
        return NameMatch(primary: instrument.id, confidence: confidence)
    }

    private func withSecondaryPass(_ match: NameMatch, remaining: String) -> NameMatch {
        let trimmed = remaining.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, let second = matchAllowingCombine(trimmed, allowSecondaryPass: false) else {
            return match
        }
        var extras = match.extras
        for id in [second.primary] + second.extras where id != match.primary && !extras.contains(id) {
            extras.append(id)
        }
        return NameMatch(primary: match.primary, extras: extras, confidence: match.confidence)
    }

    private func agrees(_ instrument: Instrument, with textNumber: Int?) -> Bool {
        guard let instrumentNumber = instrument.number, let textNumber else { return true }
        return instrumentNumber == textNumber
    }

    private func firstNumberToken(_ text: String) -> Int? {
        for word in text.split(separator: " ") where Int(word) != nil {
            return Int(word)
        }
        return nil
    }

    private func instrument(forKey key: String) -> Instrument? {
        entries.first { $0.instrument.key == key }?.instrument
    }

    /// Whether `phrase` occurs in `text` on word boundaries (i.e. not as a fragment of a larger
    /// word), treating the start/end of the string as valid boundaries.
    private func containsWholeWord(_ text: String, phrase: String) -> Bool {
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

    private func removingWholeWordSubstring(_ text: String, phrase: String) -> String {
        let textWords = text.split(separator: " ").map(String.init)
        let phraseWords = phrase.split(separator: " ").map(String.init)
        guard !phraseWords.isEmpty else { return text }
        var result = textWords
        if let start = firstRange(of: phraseWords, in: textWords) {
            result.removeSubrange(start)
        }
        return result.joined(separator: " ")
    }

    private func firstRange(of needle: [String], in haystack: [String]) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<start + needle.count]) == needle {
                return start..<(start + needle.count)
            }
        }
        return nil
    }

    private func levenshteinRatio(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        if a.isEmpty && b.isEmpty { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    current[j] = previous[j - 1]
                } else {
                    current[j] = 1 + min(previous[j - 1], previous[j], current[j - 1])
                }
            }
            swap(&previous, &current)
        }
        let distance = previous[b.count]
        return 1 - Double(distance) / Double(max(a.count, b.count))
    }
}
