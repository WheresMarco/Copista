import Foundation

struct Instrument: Codable, Identifiable, Hashable {
    var id: UUID
    var key: String?            // built-in key, e.g. "clarinet.bb.1"; nil for user-created
    var customName: String?     // user-created instruments
    var sortIndex: Int          // score order
    var defaultCopies: Int      // ≥ 0
    var includedByDefault: Bool
    var aliases: [String]       // matched case/diacritic-insensitively, any language

    var displayName: String {
        if let key {
            return String(localized: String.LocalizationValue(key), table: "Instruments")
        }
        return customName ?? ""
    }
}

enum InstrumentCatalog {
    private struct Seed: Decodable {
        let key: String
        let sortIndex: Int
        let aliases: [String]
    }

    static func seedInstruments() -> [Instrument] {
        guard let url = Bundle.main.url(forResource: "DefaultInstruments", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let seeds = try? JSONDecoder().decode([Seed].self, from: data)
        else {
            return []
        }
        return seeds.map { seed in
            Instrument(
                id: UUID(),
                key: seed.key,
                customName: nil,
                sortIndex: seed.sortIndex,
                defaultCopies: 1,
                includedByDefault: true,
                aliases: seed.aliases
            )
        }
    }
}
