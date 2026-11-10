import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        TabView {
            InstrumentsSettings()
                .tabItem { Label("Instruments", systemImage: "music.quarternote.3") }
            PrintDefaultsForm(combinedPartsUsesSum: $settings.combinedPartsUsesSum, printDefaults: $settings.printDefaults)
                .tabItem { Label("Printing", systemImage: "printer") }
            UpdatesSettings()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(minWidth: 760, minHeight: 540)
        .navigationTitle(Text("Settings", comment: "Settings window title"))
    }
}

/// The instruments by section on the left, as everywhere else in the app, and the one selected
/// on the right: what it's called, how many copies it starts with, and the names Copista looks for.
private struct InstrumentsSettings: View {
    @Environment(SettingsStore.self) private var settings
    @State private var selectedID: UUID?
    @State private var searchText = ""
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var isConfirmingReset = false
    @State private var removing: Instrument?

    private var groups: [InstrumentCatalog.SectionGroup] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? settings.instruments : settings.instruments.filter { instrument in
            instrument.displayName.localizedCaseInsensitiveContains(query)
                || instrument.aliases.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return InstrumentCatalog.grouped(matching)
    }

    private var selected: Instrument? {
        settings.instruments.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Search", text: $searchText, prompt: Text("Search instruments"))
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List(selection: $selectedID) {
                    ForEach(groups) { group in
                        Section(group.section.title) {
                            ForEach(group.instruments) { instrument in
                                InstrumentListRow(instrument: instrument)
                                    .tag(instrument.id)
                            }
                            .onMove { offsets, destination in
                                settings.moveInstruments(in: group.section, fromOffsets: offsets, toOffset: destination)
                            }
                            .moveDisabled(!searchText.isEmpty)
                        }
                    }
                }
                .onDeleteCommand { if let selected { removing = selected } }
                Divider()
                bottomBar
            }
            .frame(width: 260)

            Divider()

            Group {
                if let selected {
                    InstrumentDetail(instrument: selected)
                        .id(selected.id)
                } else {
                    ContentUnavailableView("Select an instrument", systemImage: "music.quarternote.3")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear { if selectedID == nil { selectedID = groups.first?.instruments.first?.id } }
        .confirmationDialog(
            Text("Remove “\(removing?.displayName ?? "")”?"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { instrument in
            Button("Remove", role: .destructive) {
                settings.removeInstrument(id: instrument.id)
                selectedID = nil
            }
        } message: { instrument in
            if instrument.key == nil {
                Text("Copista will stop recognizing it. Pages already sorted for it keep it.")
            } else {
                Text("Copista will stop recognizing it. You can bring it back with Restore Built-in Instruments.")
            }
        }
        .confirmationDialog("Restore the built-in instruments?", isPresented: $isConfirmingReset) {
            Button("Restore", role: .destructive) { settings.resetToSeedDefaults() }
        } message: {
            Text("Their names, copies and order go back to how Copista came. Instruments you added stay.")
        }
        .fileExporter(
            isPresented: $isExporting,
            document: SettingsExportDocument(data: settings.exportJSON() ?? Data()),
            contentType: .json,
            defaultFilename: "Copista Settings"
        ) { _ in }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            guard let url = try? result.get() else { return }
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            try? settings.importJSON(data)
        }
    }

    /// Add and remove, as under any list on a Mac, and the rarer things in a menu beside them.
    private var bottomBar: some View {
        HStack(spacing: 2) {
            Button {
                let instrument = settings.addCustomInstrument(named: String(localized: "New Instrument"), section: selected?.section ?? .other)
                searchText = ""
                selectedID = instrument.id
            } label: {
                Image(systemName: "plus").frame(width: 20, height: 16)
            }
            .help("Add an instrument of your own")
            Button {
                removing = selected
            } label: {
                Image(systemName: "minus").frame(width: 20, height: 16)
            }
            .disabled(selected == nil)
            .help("Remove the selected instrument")
            Spacer()
            Menu {
                Button("Export Settings…") { isExporting = true }
                Button("Import Settings…") { isImporting = true }
                Divider()
                Button("Restore Built-in Instruments…") { isConfirmingReset = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .buttonStyle(.borderless)
        .padding(6)
    }
}

private struct InstrumentListRow: View {
    let instrument: Instrument

    var body: some View {
        HStack {
            Text(instrument.displayName.isEmpty ? String(localized: "New Instrument") : instrument.displayName)
                .lineLimit(1)
            if instrument.key == nil {
                Image(systemName: "person.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Added by you")
            }
            Spacer()
            Text("\(instrument.startingCopies)")
                .monospacedDigit()
                .foregroundStyle(instrument.startingCopies == 0 ? .tertiary : .secondary)
                .help("Copies a new print job starts with")
        }
    }
}

private struct InstrumentDetail: View {
    let instrument: Instrument
    @Environment(SettingsStore.self) private var settings
    @State private var newName = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        Form {
            Section {
                if instrument.key == nil {
                    TextField("Name", text: binding(\.customName, default: ""))
                        .focused($isNameFocused)
                    Picker("Section", selection: binding(\.customSection, default: .other)) {
                        ForEach(InstrumentSection.allCases, id: \.self) { section in
                            Text(section.title).tag(section)
                        }
                    }
                } else {
                    LabeledContent("Name", value: instrument.displayName)
                    LabeledContent("Section", value: instrument.section.title)
                }
            } footer: {
                if instrument.key != nil {
                    Text("Built in. The name follows the language Copista is in.")
                }
            }

            Section {
                Stepper(value: copiesBinding, in: 0...50) {
                    LabeledContent("Copies", value: "\(instrument.startingCopies)")
                }
            } header: {
                Text("New print jobs")
            } footer: {
                Text("How many copies a new print job starts with. With 0 the instrument is left out, though you can still give it copies in a single job.")
            }

            Section {
                ForEach(instrument.aliases, id: \.self) { alias in
                    HStack {
                        Text(alias)
                        Spacer()
                        Button {
                            settings.removeAlias(alias, fromInstrumentID: instrument.id)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Stop recognizing this name")
                    }
                }
                HStack {
                    TextField("Add a name", text: $newName, prompt: Text("e.g. Klar 1"))
                        .labelsHidden()
                        .onSubmit(addName)
                    Button("Add", action: addName)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Names Copista recognizes")
            } footer: {
                Text("Looked for at the top of each page, and in file names. Any language; capitals and accents don't matter.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // A new instrument starts with its name ready to type over.
            if instrument.key == nil, instrument.customName == String(localized: "New Instrument") { isNameFocused = true }
        }
    }

    private func addName() {
        settings.addAlias(newName, toInstrumentID: instrument.id)
        newName = ""
    }

    private var copiesBinding: Binding<Int> {
        Binding(
            get: { instrument.startingCopies },
            set: { count in
                var updated = instrument
                updated.defaultCopies = count
                updated.includedByDefault = true
                settings.updateInstrument(updated)
            }
        )
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Instrument, Value?>, default defaultValue: Value) -> Binding<Value> {
        Binding(
            get: { instrument[keyPath: keyPath] ?? defaultValue },
            set: { value in
                var updated = instrument
                updated[keyPath: keyPath] = value
                settings.updateInstrument(updated)
            }
        )
    }
}

private struct UpdatesSettings: View {
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        @Bindable var updater = updater
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
                Toggle("Download and install them automatically", isOn: $updater.downloadsAutomatically)
                    .disabled(!updater.checksAutomatically)
            } footer: {
                Text("Copista looks for a new version on GitHub once a day. Nothing else is sent, and nothing about your music.")
            }
            Section {
                LabeledContent("Version", value: AppUpdater.versionDescription)
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            } footer: {
                if !updater.isEnabled {
                    Text("This build of Copista doesn't look for updates. Downloaded releases do.")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!updater.isEnabled)
    }
}

private struct SettingsExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
