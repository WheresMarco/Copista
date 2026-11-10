import Testing
import Foundation
@testable import Copista

@Suite struct NameMatcherTests {

    // This test target is hosted in the Copista app, so Bundle.main resolves to the app bundle
    // that actually ships DefaultInstruments.json.
    static let instruments = InstrumentCatalog.seedInstruments()
    static let matcher = NameMatcher(instruments: instruments)

    private func id(_ key: String) -> UUID {
        Self.instruments.first { $0.key == key }!.id
    }

    @Test("Catalog loads all seeded instruments")
    func catalogLoads() {
        #expect(Self.instruments.count == 61)
    }

    @Test("Every alias of every instrument resolves to that instrument", arguments: Self.instruments)
    func everyAliasResolves(_ instrument: Instrument) {
        for alias in instrument.aliases {
            let match = Self.matcher.match(alias)
            #expect(match?.primary == instrument.id, "alias '\(alias)' did not resolve to \(instrument.key ?? "?")")
        }
    }

    @Test("Stålmannen klar2 -> Clarinet 2")
    func stalmannenKlar2() {
        let text = FilenameParser.parse(FilenameParser.stripExtension("Stålmannen klar2")).matchText
        let match = Self.matcher.match(text)
        #expect(match?.primary == id("clarinet.bb.2"))
    }

    @Test("Eagle Squadron ALFORD 12 hrn3-4 -> Horn 3 + Horn 4")
    func eagleSquadronHrn34() {
        let text = FilenameParser.parse(FilenameParser.stripExtension("Eagle Squadron ALFORD 12 hrn3-4")).matchText
        let match = Self.matcher.match(text)
        #expect(match?.primary == id("horn.3"))
        #expect(match?.extras.contains(id("horn.4")) == true)
    }

    @Test("Jämtlandssångenx - Tuba 1&2 -> Tuba 1 + Tuba 2")
    func jamtlandssangenTuba() {
        let text = FilenameParser.parse(FilenameParser.stripExtension("Jämtlandssångenx - Tuba 1&2")).matchText
        let match = Self.matcher.match(text)
        #expect(match?.primary == id("tuba.1"))
        #expect(match?.extras.contains(id("tuba.2")) == true)
    }

    @Test("Olympic g-klav - Euphonium -> Euphonium (treble clef), not bass clef")
    func olympicGKlavEuphonium() {
        let text = FilenameParser.parse(FilenameParser.stripExtension("Olympic g-klav - Euphonium")).matchText
        let match = Self.matcher.match(text)
        #expect(match?.primary == id("euphonium.tc"))
        #expect(match?.primary != id("euphonium.bc"))
    }

    @Test("Trumpet in B› 2 -> Trumpet 2")
    func trumpetFlatSymbol() {
        let text = FilenameParser.parse(FilenameParser.stripExtension("Trumpet in B› 2")).matchText
        let match = Self.matcher.match(text)
        #expect(match?.primary == id("trumpet.2"))
    }

    @Test("II. Klarinett i B -> Clarinet 2 (roman numeral + Swedish 'i B' idiom)")
    func romanNumeralClarinet() {
        let text = FilenameParser.parse(FilenameParser.stripExtension("II. Klarinett i B")).matchText
        let match = Self.matcher.match(text)
        #expect(match?.primary == id("clarinet.bb.2"))
    }

    @Test("På Marsch Piccola_Flöjt2 -> Piccolo + Flute 2 combined doubling part")
    func picolaFlojt2() {
        let text = FilenameParser.parse(FilenameParser.stripExtension("På Marsch Piccola_Flöjt2")).matchText
        let match = Self.matcher.match(text)
        #expect(match?.primary == id("piccolo.1"))
        #expect(match?.extras.contains(id("flute.2")) == true)
    }

    @Test("Number agreement is a hard veto: 'klarinett 2' never resolves to Clarinet 1")
    func numberAgreementVeto() {
        let match = Self.matcher.match("klarinett 2")
        #expect(match?.primary != id("clarinet.bb.1"))
        #expect(match?.primary == id("clarinet.bb.2"))
    }

    @Test("Bare unnumbered abbreviations resolve to a combined family part", arguments: [
        ("fl", "flute.1", "flute.2"),
        ("ob", "oboe.1", "oboe.2"),
        ("alts", "sax.alto.1", "sax.alto.2"),
        ("tuba", "tuba.1", "tuba.2"),
        ("Oboes", "oboe.1", "oboe.2"),
    ])
    func bareFamilyAbbreviations(_ text: String, _ primaryKey: String, _ extraKey: String) {
        let match = Self.matcher.match(text)
        #expect(match?.primary == id(primaryKey))
        #expect(match?.extras.contains(id(extraKey)) == true)
    }

    @Test("Combined instrument on one page/filename: bass clarinet + bassoon 2")
    func combinedParenthesized() {
        let match = Self.matcher.match("baskl (fg2)")
        #expect(match?.primary == id("clarinet.bass.1"))
        #expect(match?.extras.contains(id("bassoon.2")) == true)
    }

    @Test("Bäcken Bass Drum -> Bass Drum + Cymbals combined")
    func bassDrumAndCymbals() {
        let match = Self.matcher.match("Bäcken Bass Drum")
        #expect(match?.primary == id("bassdrum"))
        #expect(match?.extras.contains(id("cymbals")) == true)
    }

    @Test("Cornet 1 in Eb resolves to the Eb cornet, not Cornet 1 (qualifier beats number)")
    func cornetQualifierBeatsNumber() {
        let match = Self.matcher.match("Cornet 1 in Eb")
        #expect(match?.primary == id("cornet.eb"))
    }
}

@Suite struct NameMatcherOCRTests {
    static let instruments = InstrumentCatalog.seedInstruments()
    static let matcher = NameMatcher(instruments: instruments)

    private func key(_ text: String, allowWordRepair: Bool = true) -> String? {
        guard let match = Self.matcher.matchOCR(text, allowWordRepair: allowWordRepair) else { return nil }
        return Self.instruments.first { $0.id == match.primary }?.key
    }

    // Every one of these is how Vision really read a hand-lettered part in the library.
    @Test("Garbled labels resolve to the right instrument and number", arguments: [
        ("End CLARINET", "clarinet.bb.2"),
        ("1S ClARINE", "clarinet.bb.1"),
        ("2nd BASSOON", "bassoon.2"),
        ("186 BASSOOM", "bassoon.1"),
        ("166 TROMPET", "trumpet.1"),
        ("3A TUMPET", "trumpet.3"),
        ("1ST HOEN InF", "horn.1"),
        ("2nd HоRт тАF", "horn.2"),
        ("1ET ROMBONE", "trombone.1"),
        ("Znd TROMBONE", "trombone.2"),
        ("3r TRОMBONE", "trombone.3"),
        ("EnG ALTOSAX", "sax.alto.2"),
        ("BABITORE", "baritone.tc"),
        ("E CLARINET", "clarinet.eb"),
        ("SASSOLAR.", "clarinet.bass.1"),
    ])
    func garbledLabels(text: String, expected: String) {
        #expect(key(text) == expected)
    }

    @Test("A repaired name is marked as uncertain")
    func repairsAreLowConfidence() {
        #expect((Self.matcher.matchOCR("1ST HOEN InF")?.confidence ?? 1) < 0.6)
        #expect((Self.matcher.matchOCR("SPA CLARINET")?.confidence ?? 1) < 0.6, "the number is only a guess")
    }

    @Test("Well-read names keep their confidence")
    func cleanNamesStayConfident() {
        #expect((Self.matcher.matchOCR("Klarinett 2")?.confidence ?? 0) >= 0.6)
        #expect((Self.matcher.matchOCR("Tuba")?.confidence ?? 0) >= 0.6)
    }

    @Test("Without word repair, text that merely resembles an instrument doesn't match")
    func wordRepairCanBeDisabled() {
        #expect(key("Cuba", allowWordRepair: false) == nil)
        #expect(key("Hemvärnets Musikkår", allowWordRepair: false) == nil)
        #expect(key("DINGE DONG", allowWordRepair: false) == nil)
    }

    @Test("Two letters on their own are a marking, unless there's a number with them", arguments: ["тр", "tp", "tr", "mf", "fp"])
    func markingsAreNotNames(text: String) {
        #expect(key(text) == nil)
    }

    @Test("A short name with its number is still a name")
    func shortNameWithNumber() {
        #expect(key("Tp 1") == "trumpet.1")
    }

    @Test("A line that is only a name, not a phrase with one in it",
          arguments: [("Eb Clarinet", true), ("TRUMPET I", true), ("Piccolo (Ad lib.)", true), ("Tuba 2.", true), ("Fagott.", true),
                      ("Trumpet Voluntary", false), ("Ballad for Tuba", false), ("Lento", false), ("Hemvärnets Musikkår", false)])
    func onlyAName(text: String, expected: Bool) {
        #expect(Self.matcher.isOnlyAName(text) == expected)
    }
}
