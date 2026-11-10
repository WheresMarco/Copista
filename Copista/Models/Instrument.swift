import Foundation
import CryptoKit

nonisolated struct Instrument: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var key: String?            // built-in key, e.g. "clarinet.bb.1"; nil for user-created
    var customName: String?     // user-created instruments
    var customSection: InstrumentSection?   // user-created instruments; built-ins go by their key
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

    var section: InstrumentSection {
        if let customSection { return customSection }
        switch key?.split(separator: ".").first {
        case "piccolo", "flute", "oboe", "englishhorn", "bassoon", "clarinet", "sax": return .woodwinds
        case "cornet", "flugelhorn", "trumpet", "horn", "tenorhorn", "baritone", "trombone", "euphonium", "tuba": return .brass
        case "doublebass": return .strings
        case "glockenspiel", "xylophone", "vibraphone", "chimes", "timpani", "snare", "bassdrum", "cymbals", "percussion": return .percussion
        case "piano", "guitar", "bassguitar": return .rhythm
        default: return .other
        }
    }

    /// Every name the matcher looks for: the aliases, and a custom instrument's own name.
    var namesToRecognize: [String] {
        aliases + [customName].compactMap { $0 }.filter { !$0.isEmpty }
    }

    /// How many copies a new print job starts with.
    var startingCopies: Int {
        includedByDefault ? defaultCopies : 0
    }

    /// The key with any trailing numeric component removed, e.g. "clarinet.bb.2" -> "clarinet.bb".
    /// Used to group numbered siblings (Clarinet 1/2/3) into a family for combined-part resolution.
    var family: String? {
        guard let key else { return nil }
        let parts = key.split(separator: ".")
        guard let last = parts.last, Int(last) != nil else { return key }
        return parts.dropLast().joined(separator: ".")
    }

    /// The trailing numeric component of the key, if any, e.g. "clarinet.bb.2" -> 2.
    var number: Int? {
        guard let key, let last = key.split(separator: ".").last else { return nil }
        return Int(last)
    }
}

nonisolated enum InstrumentSection: String, Codable, CaseIterable, Sendable {
    case woodwinds, brass, strings, percussion, rhythm, other

    var title: String {
        switch self {
        case .woodwinds: String(localized: "Woodwinds")
        case .brass: String(localized: "Brass")
        case .strings: String(localized: "Strings")
        case .percussion: String(localized: "Percussion")
        case .rhythm: String(localized: "Rhythm Section")
        case .other: String(localized: "Other")
        }
    }
}

nonisolated enum InstrumentCatalog {
    struct SectionGroup: Identifiable, Sendable {
        let section: InstrumentSection
        let instruments: [Instrument]
        var id: InstrumentSection { section }
    }

    /// Instruments by section, in score order. Everywhere instruments are listed goes through
    /// this, so they read the same on every screen.
    static func grouped(_ instruments: [Instrument]) -> [SectionGroup] {
        let sorted = instruments.sorted { $0.sortIndex < $1.sortIndex }
        return InstrumentSection.allCases.compactMap { section in
            let members = sorted.filter { $0.section == section }
            return members.isEmpty ? nil : SectionGroup(section: section, instruments: members)
        }
    }

    /// Built-in instruments get an ID derived from their key, so it means the same thing on every
    /// launch and survives a reset: saved detections refer to instruments by ID.
    static func stableID(forKey key: String) -> UUID {
        var b = Array(SHA256.hash(data: Data("copista.instrument.\(key)".utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50   // RFC 4122 name-based version
        b[8] = (b[8] & 0x3F) | 0x80   // and variant
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    struct Seed: Decodable {
        let key: String
        let sortIndex: Int
        /// The catalog version the instrument was added in. Settings saved before then don't have
        /// it yet, and get it added; ones saved after and without it had it removed on purpose.
        var since: Int?
        let aliases: [String]
    }

    /// Bump when instruments are added to `DefaultInstruments.json`, marking them with `since`.
    static let version = 2

    static func seeds(bundle: Bundle = .main) -> [Seed] {
        guard let url = bundle.url(forResource: "DefaultInstruments", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let seeds = try? JSONDecoder().decode([Seed].self, from: data)
        else {
            return []
        }
        return seeds.sorted { $0.sortIndex < $1.sortIndex }
    }

    static func seedInstruments(bundle: Bundle = .main) -> [Instrument] {
        seeds(bundle: bundle).map(instrument(from:))
    }

    static func instrument(from seed: Seed) -> Instrument {
        Instrument(
            id: stableID(forKey: seed.key),
            key: seed.key,
            customName: nil,
            sortIndex: seed.sortIndex,
            defaultCopies: 1,
            includedByDefault: true,
            aliases: seed.aliases
        )
    }
}
