import SwiftUI

/// "What instrument is '<detected text>'?" — shown for a page whose printed name didn't match
/// any known instrument. Picking one saves the raw text as an alias, so the next import of a
/// file with the same label resolves automatically.
struct UnknownNameSheet: View {
    let detectedText: String
    let pageID: UUID
    let songID: UUID

    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var selectedInstrumentID: UUID?
    @State private var rememberAlias = true

    /// Nothing was read off this page, or too much to be just a name.
    private var canRemember: Bool {
        let length = detectedText.trimmingCharacters(in: .whitespacesAndNewlines).count
        return length > 0 && length <= 40
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                if canRemember {
                    Text("What instrument is “\(detectedText)”?")
                } else {
                    Text("What instrument is this page?")
                }
            }
            .font(.headline)

            Picker("Set instrument", selection: $selectedInstrumentID) {
                Text("Choose…").tag(UUID?.none)
                ForEach(InstrumentCatalog.grouped(settings.instruments)) { group in
                    Section(group.section.title) {
                        ForEach(group.instruments) { instrument in
                            Text(instrument.displayName).tag(Optional(instrument.id))
                        }
                    }
                }
            }

            if canRemember {
                Toggle("Remember this name", isOn: $rememberAlias)
            }

            HStack {
                Button("Mark as score") {
                    model.markAsScore([pageID], inSongID: songID)
                    dismiss()
                }
                Button("Exclude page") {
                    model.excludePages([pageID], inSongID: songID)
                    dismiss()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Set instrument") {
                    guard let id = selectedInstrumentID else { return }
                    model.setInstrument(id, forPageIDs: [pageID], inSongID: songID)
                    if rememberAlias, canRemember {
                        settings.addAlias(detectedText, toInstrumentID: id)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedInstrumentID == nil)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
