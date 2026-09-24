import Foundation
import Observation

@Observable
@MainActor
final class SettingsStore {
    private(set) var instruments: [Instrument]
    var combinedPartsUsesSum: Bool

    private let fileURL: URL

    init() {
        let directory = SettingsStore.applicationSupportDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("settings.json")

        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(SettingsFile.self, from: data) {
            instruments = saved.instruments
            combinedPartsUsesSum = saved.combinedPartsUsesSum
        } else {
            instruments = InstrumentCatalog.seedInstruments()
            combinedPartsUsesSum = false
        }
    }

    func save() {
        let file = SettingsFile(instruments: instruments, combinedPartsUsesSum: combinedPartsUsesSum)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func resetToSeedDefaults() {
        instruments = InstrumentCatalog.seedInstruments()
        save()
    }

    func updateInstrument(_ instrument: Instrument) {
        guard let index = instruments.firstIndex(where: { $0.id == instrument.id }) else { return }
        instruments[index] = instrument
        save()
    }

    func addInstrument(_ instrument: Instrument) {
        instruments.append(instrument)
        save()
    }

    func removeInstrument(id: UUID) {
        instruments.removeAll { $0.id == id }
        save()
    }

    func moveInstruments(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let moving = offsets.map { instruments[$0] }
        var remaining = instruments
        for index in offsets.sorted(by: >) {
            remaining.remove(at: index)
        }
        let adjustedDestination = destination - offsets.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: adjustedDestination)
        instruments = remaining
        for index in instruments.indices {
            instruments[index].sortIndex = index
        }
        save()
    }

    private static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Copista", isDirectory: true)
    }
}

private struct SettingsFile: Codable {
    var instruments: [Instrument]
    var combinedPartsUsesSum: Bool
}
