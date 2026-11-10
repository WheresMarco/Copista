import Foundation
import Observation
import CryptoKit

@Observable
@MainActor
final class SettingsStore {
    private(set) var instruments: [Instrument]
    var combinedPartsUsesSum: Bool {
        didSet { save() }
    }
    var printDefaults: PrintDefaults {
        didSet { save() }
    }
    /// Whether the welcome guide has been finished or skipped. Settings files from before there
    /// was a guide don't have this, so people already using the app get to see it once too.
    var hasCompletedWelcome: Bool {
        didSet { save() }
    }

    private let fileURL: URL

    /// Bump when `DocumentAnalyzer` improves enough that saved results should be redone.
    private static let analyzerVersion = 3

    init(directory: URL = SettingsStore.applicationSupportDirectory()) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("settings.json")

        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(SettingsFile.self, from: data) {
            instruments = Self.updatingCatalog(saved.instruments, from: saved.catalogVersion ?? 1)
            combinedPartsUsesSum = saved.combinedPartsUsesSum
            printDefaults = saved.printDefaults ?? PrintDefaults()
            hasCompletedWelcome = saved.hasCompletedWelcome ?? false
            if saved.catalogVersion != InstrumentCatalog.version { save() }
        } else {
            instruments = InstrumentCatalog.seedInstruments()
            combinedPartsUsesSum = false
            printDefaults = PrintDefaults()
            hasCompletedWelcome = false
        }
    }

    /// A settings file holds its own copy of the catalog, so what a later version of the app adds
    /// to the built-in one has to be merged in: once, so that what's been removed since stays gone.
    /// New instruments go in after the one they follow in the built-in order.
    private static func updatingCatalog(_ saved: [Instrument], from version: Int) -> [Instrument] {
        guard version < InstrumentCatalog.version else { return saved }
        let seeds = InstrumentCatalog.seeds()
        var instruments = saved.sorted { $0.sortIndex < $1.sortIndex }.map { instrument in
            guard let seed = seeds.first(where: { $0.key == instrument.key }) else { return instrument }
            var merged = instrument
            merged.aliases += seed.aliases.filter { !instrument.aliases.contains($0) }
            return merged
        }
        for (seedIndex, seed) in seeds.enumerated() where (seed.since ?? 1) > version && !instruments.contains(where: { $0.key == seed.key }) {
            let previousKeys = seeds[..<seedIndex].map(\.key)
            let insertAt = instruments.lastIndex { previousKeys.contains($0.key ?? "") }.map { $0 + 1 } ?? 0
            instruments.insert(InstrumentCatalog.instrument(from: seed), at: insertAt)
        }
        for index in instruments.indices { instruments[index].sortIndex = index }
        return instruments
    }

    /// Identifies the analyzer and everything in the catalog that affects a detection's outcome.
    var catalogSignature: String {
        let catalog = instruments
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { "\($0.id.uuidString):\($0.namesToRecognize.joined(separator: ","))" }
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data("\(Self.analyzerVersion)|\(catalog)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func save() {
        guard let data = exportJSON() else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Puts the built-in instruments back as they came, keeping any ID an instrument already has,
    /// so songs already imported (and settings files from before IDs became stable) still resolve.
    /// Instruments of your own stay, each at the end of its section.
    func resetToSeedDefaults() {
        let existingIDs = Dictionary(instruments.compactMap { i in i.key.map { ($0, i.id) } }, uniquingKeysWith: { first, _ in first })
        let custom = instruments.filter { $0.key == nil }
        instruments = InstrumentCatalog.seedInstruments().map { seed in
            var instrument = seed
            if let key = seed.key, let id = existingIDs[key] { instrument.id = id }
            return instrument
        }
        for instrument in custom { place(instrument) }
        save()
    }

    func updateInstrument(_ instrument: Instrument) {
        guard let index = instruments.firstIndex(where: { $0.id == instrument.id }) else { return }
        let movedSection = instruments[index].section != instrument.section
        instruments[index] = instrument
        if movedSection {
            instruments.remove(at: index)
            place(instrument)
        }
        save()
    }

    /// An instrument of your own, at the end of its section, as a new player is seated.
    @discardableResult
    func addCustomInstrument(named name: String, section: InstrumentSection) -> Instrument {
        let instrument = Instrument(
            id: UUID(), key: nil, customName: name, customSection: section, sortIndex: 0,
            defaultCopies: 1, includedByDefault: true, aliases: []
        )
        place(instrument)
        save()
        return instrument
    }

    /// Adds an instrument after the last one in its section, and numbers them all again.
    private func place(_ instrument: Instrument) {
        var ordered = instruments.sorted { $0.sortIndex < $1.sortIndex }
        let sections = InstrumentSection.allCases
        let rank = sections.firstIndex(of: instrument.section) ?? sections.count
        let insertAt = ordered.lastIndex { (sections.firstIndex(of: $0.section) ?? sections.count) <= rank }.map { $0 + 1 } ?? 0
        ordered.insert(instrument, at: insertAt)
        for index in ordered.indices { ordered[index].sortIndex = index }
        instruments = ordered
    }

    /// Sets the copies every new print job starts with. All at once, since the guide changes
    /// dozens of instruments and each save rewrites the file. A count of 0 is what leaves
    /// an instrument out, so they all count as included from here on.
    func setDefaultCopies(_ copies: [UUID: Int]) {
        for index in instruments.indices {
            guard let count = copies[instruments[index].id] else { continue }
            instruments[index].defaultCopies = count
            instruments[index].includedByDefault = true
        }
        save()
    }

    func removeInstrument(id: UUID) {
        instruments.removeAll { $0.id == id }
        save()
    }

    /// Reorders one section's instruments, as listed in it. This is the order parts print in.
    func moveInstruments(in section: InstrumentSection, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let ordered = instruments.sorted { $0.sortIndex < $1.sortIndex }
        var members = ordered.filter { $0.section == section }
        let moving = offsets.map { members[$0] }
        for index in offsets.sorted(by: >) { members.remove(at: index) }
        members.insert(contentsOf: moving, at: destination - offsets.filter { $0 < destination }.count)
        // Back into the places the section had, so other sections stay where they are.
        var next = members.makeIterator()
        instruments = ordered.map { $0.section == section ? next.next()! : $0 }
        for index in instruments.indices { instruments[index].sortIndex = index }
        save()
    }

    /// Records a name that resolved incorrectly (or not at all) as a recognized alias for the
    /// instrument the user picked, so the next import recognizes it automatically.
    func addAlias(_ alias: String, toInstrumentID id: UUID) {
        guard let index = instruments.firstIndex(where: { $0.id == id }) else { return }
        let normalized = alias.trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty, !instruments[index].aliases.contains(normalized) else { return }
        instruments[index].aliases.append(normalized)
        save()
    }

    func removeAlias(_ alias: String, fromInstrumentID id: UUID) {
        guard let index = instruments.firstIndex(where: { $0.id == id }) else { return }
        instruments[index].aliases.removeAll { $0 == alias }
        save()
    }

    func exportJSON() -> Data? {
        try? JSONEncoder().encode(SettingsFile(
            instruments: instruments, combinedPartsUsesSum: combinedPartsUsesSum,
            printDefaults: printDefaults, hasCompletedWelcome: hasCompletedWelcome, catalogVersion: InstrumentCatalog.version
        ))
    }

    func importJSON(_ data: Data) throws {
        let file = try JSONDecoder().decode(SettingsFile.self, from: data)
        instruments = Self.updatingCatalog(file.instruments, from: file.catalogVersion ?? 1)
        combinedPartsUsesSum = file.combinedPartsUsesSum
        printDefaults = file.printDefaults ?? PrintDefaults()
        save()
    }

    nonisolated private static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Copista", isDirectory: true)
    }
}

/// How a new print job starts out.
nonisolated struct PrintDefaults: Codable, Hashable, Sendable {
    var isDoubleSided = false
    var includesScore = false
    var scoreCopies = 1
}

private struct SettingsFile: Codable {
    var instruments: [Instrument]
    var combinedPartsUsesSum: Bool
    var printDefaults: PrintDefaults?
    var hasCompletedWelcome: Bool?
    /// The built-in catalog's `InstrumentCatalog.version` when this was saved. Missing: version 1.
    var catalogVersion: Int?
}
