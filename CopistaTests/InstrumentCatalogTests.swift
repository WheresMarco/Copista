import Testing
import Foundation
@testable import Copista

@Suite @MainActor struct InstrumentCatalogTests {
    private func store() throws -> (SettingsStore, URL) {
        let directory = try PDFFixtures.directory("support")
        return (SettingsStore(directory: directory), directory)
    }

    @Test("Every built-in instrument has a name in both languages, a section, and no name shared with another")
    func builtInsAreComplete() throws {
        let instruments = InstrumentCatalog.seedInstruments()
        #expect(instruments.allSatisfy { !$0.displayName.isEmpty && $0.displayName != $0.key })
        #expect(instruments.allSatisfy { $0.section != .other })
        var owners: [String: Set<String>] = [:]
        for instrument in instruments {
            for alias in instrument.aliases { owners[TextNormalizer.normalize(alias), default: []].insert(instrument.key ?? "") }
        }
        #expect(owners.filter { $0.value.count > 1 }.isEmpty)
    }

    @Test("Names found in the real library are recognized", arguments: [
        ("Flygelhorn 2", "flugelhorn.2"), ("2. Alt Saxophon", "sax.alto.2"), ("Electric Bass Guitar", "bassguitar"), ("Vibraphone", "vibraphone"),
        ("Chimes", "chimes"), ("1. Alt -Saxophon", "sax.alto.1"), ("Ten.sax", "sax.tenor"), ("Esskorn.", "cornet.eb"),
        ("Bass in Eb", "tuba.1"), ("Drums", "percussion.1"), ("Trumpet 4", "trumpet.4"),
    ])
    func newNames(text: String, key: String) {
        let instruments = InstrumentCatalog.seedInstruments()
        let match = NameMatcher(instruments: instruments).matchOCR(text)
        #expect(instruments.first { $0.id == match?.primary }?.key == key)
    }

    @Test("An instrument of your own is recognized by its name, and goes at the end of its section")
    func customInstrument() throws {
        let (settings, _) = try store()
        let added = settings.addCustomInstrument(named: "Säckpipa", section: .woodwinds)

        let ordered = settings.instruments.sorted { $0.sortIndex < $1.sortIndex }
        let lastWoodwind = ordered.last { $0.section == .woodwinds }
        #expect(lastWoodwind?.id == added.id)
        #expect(NameMatcher(instruments: settings.instruments).match("Säckpipa")?.primary == added.id)
    }

    @Test("Moving your own instrument to another section moves it in the order too")
    func changeSection() throws {
        let (settings, _) = try store()
        var added = settings.addCustomInstrument(named: "Säckpipa", section: .woodwinds)
        added.customSection = .percussion
        settings.updateInstrument(added)
        let ordered = settings.instruments.sorted { $0.sortIndex < $1.sortIndex }
        #expect(ordered.last { $0.section == .percussion }?.id == added.id)
    }

    @Test("Your own instruments survive a relaunch and a restore of the built-ins")
    func customSurvives() throws {
        let (settings, directory) = try store()
        let added = settings.addCustomInstrument(named: "Säckpipa", section: .other)
        settings.resetToSeedDefaults()
        #expect(settings.instruments.contains { $0.id == added.id })
        #expect(SettingsStore(directory: directory).instruments.first { $0.id == added.id }?.customName == "Säckpipa")
    }

    @Test("Settings from before the new instruments get them once, in score order; one removed after stays removed")
    func catalogUpgrade() throws {
        let (settings, directory) = try store()
        // As saved by the previous version: the original instruments only, no catalog version.
        let file = directory.appendingPathComponent("settings.json")
        settings.combinedPartsUsesSum = true
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let newKeys = Set(InstrumentCatalog.seeds().filter { ($0.since ?? 1) > 1 }.map(\.key))
        json["instruments"] = (json["instruments"] as? [[String: Any]])?.filter { !newKeys.contains($0["key"] as? String ?? "") }
        json["catalogVersion"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: file)

        let upgraded = SettingsStore(directory: directory)
        let keys = upgraded.instruments.sorted { $0.sortIndex < $1.sortIndex }.compactMap(\.key)
        #expect(keys == InstrumentCatalog.seeds().map(\.key))

        let flugelhorn = try #require(upgraded.instruments.first { $0.key == "flugelhorn.1" })
        upgraded.removeInstrument(id: flugelhorn.id)
        #expect(!SettingsStore(directory: directory).instruments.contains { $0.key == "flugelhorn.1" })
    }

    @Test("A section's instruments can be put in another order without touching the rest")
    func reorderWithinSection() throws {
        let (settings, _) = try store()
        let before = settings.instruments.sorted { $0.sortIndex < $1.sortIndex }
        let brass = before.filter { $0.section == .brass }
        settings.moveInstruments(in: .brass, fromOffsets: [0], toOffset: 2)
        let after = settings.instruments.sorted { $0.sortIndex < $1.sortIndex }
        #expect(after.filter { $0.section == .brass }.map(\.id).prefix(2) == [brass[1].id, brass[0].id])
        #expect(after.filter { $0.section != .brass }.map(\.id) == before.filter { $0.section != .brass }.map(\.id))
    }
}
