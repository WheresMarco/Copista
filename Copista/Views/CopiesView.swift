import SwiftUI

struct CopiesView: View {
    @Environment(AppModel.self) private var model
    @State private var showAll = false

    private struct Row: Identifiable {
        let id: UUID
        let name: String
        let songCount: Int
        let pagesEach: Int
        let totalPages: Int
    }

    private struct RowGroup: Identifiable {
        let section: InstrumentSection
        let rows: [Row]
        var id: InstrumentSection { section }
    }

    private var rowGroups: [RowGroup] {
        let parts = model.songs.flatMap(\.parts)
        return InstrumentCatalog.grouped(model.settings.instruments).compactMap { group in
            let rows = group.instruments.compactMap { instrument -> Row? in
                let ownParts = parts.filter { $0.kind == .instrument(instrument.id) }
                // A combined part ("Horn 1/3") also counts for the instrument it's shared with.
                let sharedParts = parts.filter { $0.extraInstruments.contains(instrument.id) }
                guard !ownParts.isEmpty || !sharedParts.isEmpty || showAll else { return nil }
                let totalPages = ownParts.reduce(0) { total, part in
                    total + part.pages.count * OutputPlanner.copyCount(for: part, job: model.printJob, combinedPartsUsesSum: model.settings.combinedPartsUsesSum)
                }
                return Row(
                    id: instrument.id,
                    name: instrument.displayName,
                    songCount: ownParts.count + sharedParts.count,
                    pagesEach: (ownParts + sharedParts).reduce(0) { $0 + $1.pages.count },
                    totalPages: totalPages
                )
            }
            return rows.isEmpty ? nil : RowGroup(section: group.section, rows: rows)
        }
    }

    private var songsWithScore: [Song] {
        model.songs.filter { $0.scorePart != nil }
    }

    private var scorePagesEach: Int {
        let included = songsWithScore.filter(\.includeScore)
        return (included.isEmpty ? songsWithScore : included).reduce(0) { $0 + ($1.scorePart?.pages.count ?? 0) }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if !songsWithScore.isEmpty {
                ScoreRow(
                    pagesEach: scorePagesEach,
                    includeScore: Binding(
                        get: { songsWithScore.contains(where: \.includeScore) },
                        set: { model.setIncludeScoreForAllSongs($0) }
                    ),
                    copies: Binding(get: { model.printJob.scoreCopies }, set: { model.setScoreCopies($0) })
                )
                .padding(.horizontal)
                .padding(.top, 8)

                Divider().padding(.vertical, 4)
            }

            Table(of: Row.self) {
                TableColumn("Instrument") { row in Text(row.name) }
                TableColumn("Songs") { row in Text("\(row.songCount)") }
                TableColumn("Copies") { row in
                    Stepper(value: copiesBinding(for: row.id), in: 0...50) {
                        Text("\(model.printJob.copies[row.id] ?? 0)")
                    }
                }
                TableColumn("Pages each") { row in Text("\(row.pagesEach)") }
                TableColumn("Total pages") { row in
                    // Zero with music to play means it's all in a part counted under another row.
                    Text(row.totalPages == 0 && row.pagesEach > 0 ? "–" : "\(row.totalPages)")
                }
            } rows: {
                ForEach(rowGroups) { group in
                    Section(group.section.title) {
                        ForEach(group.rows) { row in
                            TableRow(row)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Toggle("Show all instruments", isOn: $showAll)
                Spacer()
                Text("Total: \(model.outputPlans.reduce(0) { $0 + $1.plan.musicPageCount }) pages")
                Button("Reset to defaults") { resetToDefaults() }
                Button("Save as defaults") { saveAsDefaults() }
            }
            .padding()
        }
    }

    private func copiesBinding(for instrumentID: UUID) -> Binding<Int> {
        Binding(
            get: { model.printJob.copies[instrumentID] ?? 0 },
            set: { model.setCopies([instrumentID: $0]) }
        )
    }

    private func resetToDefaults() {
        model.setCopies(Dictionary(model.settings.instruments.map { ($0.id, $0.startingCopies) }, uniquingKeysWith: { first, _ in first }))
    }

    private func saveAsDefaults() {
        for instrument in model.settings.instruments {
            var updated = instrument
            updated.defaultCopies = model.printJob.copies[instrument.id] ?? instrument.defaultCopies
            model.settings.updateInstrument(updated)
        }
    }
}

private struct ScoreRow: View {
    let pagesEach: Int
    @Binding var includeScore: Bool
    @Binding var copies: Int

    var body: some View {
        HStack {
            Toggle(isOn: $includeScore) {
                Text("Score", comment: "Full orchestral score (partitur)").bold()
            }
            .toggleStyle(.checkbox)
            Spacer()
            Text("\(pagesEach) pages each")
            Stepper(value: $copies, in: 0...50) {
                Text("\(copies) copies")
            }
            .disabled(!includeScore)
        }
    }
}
