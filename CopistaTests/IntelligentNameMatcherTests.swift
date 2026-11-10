import Testing
import Foundation
import FoundationModels
@testable import Copista

/// `IntelligentNameMatcher` wraps an OS 26+ on-device model, so every test here must tolerate
/// running on an older deployment target or a machine without Apple Intelligence enabled — the
/// whole point of the type is to degrade to a no-op in exactly those cases.
@Suite struct IntelligentNameMatcherTests {

    static var isMacOS26OrLater: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static var isIntelligenceAvailable: Bool {
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        return false
    }

    @Test("An empty catalog never matches, and never touches the model", .enabled(if: isMacOS26OrLater))
    func emptyInstrumentsNeverMatches() async {
        guard #available(macOS 26.0, *) else { return }
        let matcher = IntelligentNameMatcher(instruments: [])
        let result = await matcher.match("some garbled ocr text")
        #expect(result == nil)
    }

    @Test("A custom instrument with no built-in key is excluded from the catalog", .enabled(if: isMacOS26OrLater))
    func keylessInstrumentsAreExcluded() async {
        guard #available(macOS 26.0, *) else { return }
        let custom = Instrument(
            id: UUID(), key: nil, customName: "Kazoo", sortIndex: 0,
            defaultCopies: 1, includedByDefault: true, aliases: ["kazoo"]
        )
        let matcher = IntelligentNameMatcher(instruments: [custom])
        // With no keyed candidates the matcher must behave exactly like an empty catalog: it
        // should never reach the model, so this stays fast and deterministic.
        let result = await matcher.match("kazoo")
        #expect(result == nil)
    }

    @Test(
        "A garbled OCR candidate resolves to a real catalog id (or is declined) when Apple Intelligence is available",
        .enabled(if: isIntelligenceAvailable)
    )
    func realGarbledTextAttemptsAPlausibleMatch() async {
        guard #available(macOS 26.0, *) else { return }
        // "gıodIsV" is the actual low-confidence OCR reading Vision produced for Valborg - Parts.pdf
        // (see RealLibraryVerificationTests.valborgPartsResolves) — its characters approximate
        // "VALBORG" in reverse, which is exactly the kind of garbling this fallback exists for.
        let instruments = InstrumentCatalog.seedInstruments()
        let matcher = IntelligentNameMatcher(instruments: instruments)
        let result = await matcher.match("gıodIsV")
        // The on-device model's exact judgment isn't a contract this test can pin down, so it
        // only asserts the call completes and, if it does answer, that the answer is a real
        // catalog id rather than something hallucinated outside the guided-generation schema.
        if let result {
            #expect(instruments.contains { $0.id == result })
        }
    }
}
