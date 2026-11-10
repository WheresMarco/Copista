import Foundation
import FoundationModels

/// A last-resort fallback for OCR text that `NameMatcher`'s deterministic rules couldn't resolve:
/// hands the raw candidate text, plus the catalog's instrument names and aliases, to the on-device
/// Apple Intelligence model and asks it to pick the closest match, constrained to the known
/// instrument keys (or "none"). Guided generation (`DynamicGenerationSchema`) guarantees the model
/// can only answer with a key that's actually in the catalog, or "none" — never a hallucinated key.
///
/// This never runs *instead* of `NameMatcher`, only after it has already given up on a page, and
/// it degrades to a no-op wherever Apple Intelligence isn't available (unsupported hardware, the
/// feature disabled, or the on-device model not yet downloaded) — callers get `nil` and fall back
/// to whatever they'd have done without this matcher.
nonisolated struct IntelligentNameMatcher: Sendable {
    private struct Candidate: Sendable {
        let id: UUID
        let key: String
        let label: String
    }

    private let candidates: [Candidate]

    init(instruments: [Instrument]) {
        candidates = instruments.compactMap { instrument in
            guard let key = instrument.key else { return nil }
            let aliases = instrument.aliases.prefix(6).joined(separator: ", ")
            return Candidate(id: instrument.id, key: key, label: "\(instrument.displayName) (\(aliases))")
        }
    }

    @available(macOS 26.0, *)
    var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// Returns the id of the best-matching instrument for `text`, or `nil` if the model judged
    /// nothing plausible, Apple Intelligence isn't available, or generation failed for any reason.
    @available(macOS 26.0, *)
    func match(_ text: String) async -> UUID? {
        guard isAvailable, !candidates.isEmpty else { return nil }

        let choices = candidates.map(\.key) + ["none"]
        let root = DynamicGenerationSchema(
            name: "InstrumentGuess",
            description: "The catalog key of the best-matching instrument, or \"none\" if nothing plausibly matches",
            anyOf: choices
        )

        let catalog = candidates.map { "\($0.key): \($0.label)" }.joined(separator: "\n")
        let instructions = """
            You are matching a short, possibly garbled piece of OCR text taken from the top of a \
            page of wind-band sheet music to the instrument part it names. The text may be \
            misspelled, abbreviated, missing spaces, or have characters in the wrong order — a \
            scanning artifact. Pick the best match from the catalog below by its key. If the text \
            is not an instrument name at all — a title, a composer, a tempo marking, a publisher, \
            a stamp — or nothing in the catalog plausibly matches, answer "none". Answer with only \
            the key.

            Catalog (key: name and known aliases):
            \(catalog)
            """

        do {
            let schema = try GenerationSchema(root: root, dependencies: [])
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: "OCR text: \"\(text)\"", schema: schema)
            let key = try response.content.value(String.self)
            guard key != "none" else { return nil }
            return candidates.first { $0.key == key }?.id
        } catch {
            return nil
        }
    }
}
