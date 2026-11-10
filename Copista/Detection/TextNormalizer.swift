import Foundation

/// Character-level normalization shared by every instrument name comparison: filenames, OCR
/// text, and the alias table itself all pass through this before anything is compared, so both
/// sides of a comparison always end up in the same canonical form.
nonisolated enum TextNormalizer {

    /// Full normalization: lowercase, fold diacritics (keeping å/ä/ö, since those are
    /// meaningful Swedish letters, not accents), map Nordic look-alikes, collapse the various
    /// "B-flat"/"E-flat" spellings musicians use to `bb`/`eb`, split jammed letter+digit tokens
    /// (`klar2` -> `klar 2`), turn separator punctuation into spaces, and spell out roman
    /// numerals and ordinals as plain digits.
    ///
    /// Deliberately does NOT convert a bare "i" to the roman numeral 1: unlike ii/iii/iv, a
    /// standalone "i" collides with the Swedish preposition "i" ("in"), as in "Klarinett i B"
    /// (Clarinet in B[b]) — treating that "i" as a numeral would misread the part number.
    static func normalize(_ input: String) -> String {
        var s = input.lowercased()

        s = s.replacingOccurrences(of: "ø", with: "ö")
        s = s.replacingOccurrences(of: "æ", with: "ä")

        // Key-qualifier spellings, before diacritics/punctuation touch them.
        s = s.replacingOccurrences(of: "b♭", with: "bb")
        s = s.replacingOccurrences(of: "b›", with: "bb")
        s = s.replacingOccurrences(of: "e♭", with: "eb")

        s = foldDiacritics(s)

        // Separator punctuation -> space (parens, underscores, dashes, commas, periods).
        for ch in ["_", "-", ".", ",", "(", ")", "/", "&"] {
            s = s.replacingOccurrences(of: ch, with: " ")
        }

        s = insertLetterDigitBoundaries(s)
        s = collapseWhitespace(s)
        s = mapWordTokens(s)
        s = collapseWhitespace(s)
        return s
    }

    /// Like `normalize`, but keeps `/ - & ,` intact so a caller can look for combined-number
    /// patterns (`1/3`, `1-2`, `1&2`, `1, 3`) before those separators are erased.
    static func normalizeKeepingSeparators(_ input: String) -> String {
        var s = input.lowercased()
        s = s.replacingOccurrences(of: "ø", with: "ö")
        s = s.replacingOccurrences(of: "æ", with: "ä")
        s = s.replacingOccurrences(of: "b♭", with: "bb")
        s = s.replacingOccurrences(of: "b›", with: "bb")
        s = s.replacingOccurrences(of: "e♭", with: "eb")
        s = foldDiacritics(s)
        for ch in ["_", ".", "("] { s = s.replacingOccurrences(of: ch, with: " ") }
        s = s.replacingOccurrences(of: ")", with: " ")
        s = insertLetterDigitBoundaries(s)
        s = collapseWhitespace(s)
        return s
    }

    /// Finishes a string produced by `normalizeKeepingSeparators` once the caller is done
    /// looking for combined-number patterns: erases the remaining separators and maps word
    /// tokens (roman numerals, ordinals, the "i b" -> "bb" idiom).
    static func finish(_ input: String) -> String {
        var s = input
        for ch in ["/", "-", "&", ","] { s = s.replacingOccurrences(of: ch, with: " ") }
        s = collapseWhitespace(s)
        s = mapWordTokens(s)
        return collapseWhitespace(s)
    }

    /// Vision sometimes reads a Latin capital as its Cyrillic twin (`HоRN`, `TRОMBONE`).
    static func foldCyrillicLookalikes(_ s: String) -> String {
        let table: [Character: Character] = [
            "А": "A", "В": "B", "С": "C", "Е": "E", "Н": "H", "І": "I", "К": "K", "М": "M", "О": "O",
            "Р": "P", "Т": "T", "Х": "X", "а": "a", "с": "c", "е": "e", "і": "i", "м": "m", "о": "o",
            "р": "p", "т": "t", "х": "x",
        ]
        return String(s.map { table[$0] ?? $0 })
    }

    /// The part number in a leading ordinal as OCR tends to garble it on old hand-lettered parts:
    /// `1S`, `186`, `1ET` for "1st", `End`, `Znd`, `EnG` for "2nd", `3A`, `3r` for "3rd".
    static func garbledOrdinal(_ word: String) -> Int? {
        let w = word.lowercased()
        if w.range(of: #"^[1-4][\p{L}\d&+]{0,2}$"#, options: .regularExpression) != nil, let first = w.first {
            return first.wholeNumberValue
        }
        if w.range(of: #"^[lIi]st$"#, options: [.regularExpression, .caseInsensitive]) != nil { return 1 }
        if w.range(of: #"^[zse]n[dg]$"#, options: .regularExpression) != nil { return 2 }
        return nil
    }

    private static func foldDiacritics(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "å", "ä", "ö":
                result.unicodeScalars.append(scalar)
            default:
                let folded = String(scalar).folding(options: .diacriticInsensitive, locale: nil)
                result += folded
            }
        }
        return result
    }

    private static func insertLetterDigitBoundaries(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count + 8)
        var previousWasDigit: Bool?
        for ch in s {
            let isDigit = ch.isNumber
            let isLetter = ch.isLetter
            if let prev = previousWasDigit, isLetter || isDigit {
                if prev != isDigit && (isLetter || isDigit) {
                    result.append(" ")
                }
            }
            result.append(ch)
            if isLetter || isDigit {
                previousWasDigit = isDigit
            } else {
                previousWasDigit = nil
            }
        }
        return result
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static let romanNumerals: [String: String] = ["ii": "2", "iii": "3", "iv": "4"]
    private static let ordinals: [String: String] = ["1st": "1", "2nd": "2", "3rd": "3", "4th": "4"]

    private static func mapWordTokens(_ s: String) -> String {
        var words = s.split(separator: " ").map(String.init)

        // Swedish idiom: "i b" (in B[b]) -> "bb". Only the bare single-letter word "b",
        // immediately after the preposition "i", triggers this; "in bb" is untouched.
        var i = 0
        while i < words.count - 1 {
            if words[i] == "i", words[i + 1] == "b" {
                words[i] = "bb"
                words.remove(at: i + 1)
            } else {
                i += 1
            }
        }

        words = words.map { romanNumerals[$0] ?? ordinals[$0] ?? $0 }
        return words.joined(separator: " ")
    }
}
