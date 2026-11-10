import SwiftUI

/// The first-launch setup, also available again from the Help menu. Nothing is applied until the
/// last step, so skipping halfway leaves everything as it was.
struct WelcomeGuideView: View {
    private enum Step: Int, CaseIterable {
        case welcome, ensemble, printing, finished
    }

    let onFinish: (_ wantsToAddFiles: Bool) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .welcome
    @State private var copies: [UUID: Int]
    @State private var combinedPartsUsesSum: Bool
    @State private var printDefaults: PrintDefaults

    private let instruments: [Instrument]

    init(settings: SettingsStore, onFinish: @escaping (_ wantsToAddFiles: Bool) -> Void) {
        self.onFinish = onFinish
        instruments = settings.instruments.sorted { $0.sortIndex < $1.sortIndex }
        _copies = State(initialValue: Dictionary(uniqueKeysWithValues: settings.instruments.map { ($0.id, $0.startingCopies) }))
        _combinedPartsUsesSum = State(initialValue: settings.combinedPartsUsesSum)
        _printDefaults = State(initialValue: settings.printDefaults)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcomeStep
                case .ensemble: ensembleStep
                case .printing: printingStep
                case .finished: finishedStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 680, height: 620)
        .interactiveDismissDisabled()
    }

    private var footer: some View {
        HStack {
            if step != .finished {
                Button("Skip") { skip() }
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { candidate in
                    Circle()
                        .fill(candidate == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)
            Spacer()
            if step != .welcome {
                Button("Back") { go(by: -1) }
            }
            if step == .finished {
                Button("Done") { finish(wantsToAddFiles: false) }
                Button("Add Files…") { finish(wantsToAddFiles: true) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { go(by: 1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            AppIconImage()
            VStack(spacing: 8) {
                Text("Welcome to Copista")
                    .brandHeadingFont(.largeTitle.bold())
                Text("From a pile of PDFs to a stack of parts ready to print, with the right number of copies for everyone.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                WelcomeRow(systemImage: "doc.badge.plus", title: Text("Add"), detail: Text("Drop in PDFs or whole folders, scanned or not. Files added together become one song, and Copista works out which page belongs to which instrument."))
                WelcomeRow(systemImage: "eye", title: Text("Review"), detail: Text("Pages it isn't sure about are marked, so you only need to look at those."))
                WelcomeRow(systemImage: "printer", title: Text("Print"), detail: Text("Set the copies, check the list of warnings, and print or save a PDF."))
            }
            .frame(maxWidth: 480)
            Text("Setting up takes a minute. You can change everything later.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }

    private var ensembleStep: some View {
        VStack(spacing: 0) {
            StepHeader(
                title: Text("How many copies of each part?"),
                detail: Text("Usually one per musician. Set 0 for instruments you don't have, and those parts won't print.")
            )
            HStack {
                Text("Total: \(copies.values.reduce(0, +)) copies")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Set All to 1") { setAll(to: 1) }
                Button("Set All to 0") { setAll(to: 0) }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(InstrumentCatalog.grouped(instruments)) { group in
                        let splitIndex = (group.instruments.count + 1) / 2
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.section.title).brandHeadingFont(.headline)
                            // Filled column by column, so Klarinett 1, 2, 3 read straight down.
                            HStack(alignment: .top, spacing: 24) {
                                copyCountColumn(group.instruments[..<splitIndex])
                                copyCountColumn(group.instruments[splitIndex...])
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    private func copyCountColumn(_ members: ArraySlice<Instrument>) -> some View {
        VStack(spacing: 6) {
            ForEach(members) { instrument in
                CopyCountRow(name: instrument.displayName, count: binding(for: instrument.id))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var printingStep: some View {
        VStack(spacing: 0) {
            StepHeader(
                title: Text("How do you print?"),
                detail: Text("These are the starting point for every new print job. You can still change them for a single job.")
            )
            PrintDefaultsForm(combinedPartsUsesSum: $combinedPartsUsesSum, printDefaults: $printDefaults)
        }
    }

    private var finishedStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("You're all set")
                    .brandHeadingFont(.largeTitle.bold())
                Text("Add your first songs whenever you're ready.")
                    .foregroundStyle(.secondary)
            }
            Text("Change these later under Copista > Settings, or go through this guide again from the Help menu.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(32)
    }

    // MARK: - Actions

    private func go(by offset: Int) {
        if let next = Step(rawValue: step.rawValue + offset) { step = next }
    }

    private func binding(for id: UUID) -> Binding<Int> {
        Binding(
            get: { copies[id] ?? 0 },
            set: { copies[id] = min(max($0, 0), 50) }
        )
    }

    private func setAll(to count: Int) {
        for id in copies.keys { copies[id] = count }
    }

    private func skip() {
        model.settings.hasCompletedWelcome = true
        dismiss()
    }

    private func finish(wantsToAddFiles: Bool) {
        let settings = model.settings
        settings.setDefaultCopies(copies)
        settings.combinedPartsUsesSum = combinedPartsUsesSum
        settings.printDefaults = printDefaults
        settings.hasCompletedWelcome = true
        model.applyDefaultsToPrintJob()
        onFinish(wantsToAddFiles)
        dismiss()
    }
}

private struct StepHeader: View {
    let title: Text
    let detail: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            title.brandHeadingFont()
            detail.foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }
}

private struct WelcomeRow: View {
    let systemImage: String
    let title: Text
    let detail: Text

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.brandInk)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title.font(.headline)
                detail.foregroundStyle(.secondary)
            }
        }
    }
}

private struct CopyCountRow: View {
    let name: String
    @Binding var count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .lineLimit(1)
                .foregroundStyle(count == 0 ? .secondary : .primary)
            Spacer()
            TextField(name, value: $count, format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
            Stepper(name, value: $count, in: 0...50)
                .labelsHidden()
        }
    }
}

/// The settings that decide how a new print job starts out. Shared by the welcome guide and the
/// Settings window, so the two can't drift apart in what they offer or how they explain it.
struct PrintDefaultsForm: View {
    @Binding var combinedPartsUsesSum: Bool
    @Binding var printDefaults: PrintDefaults

    var body: some View {
        Form {
            Section {
                Picker("Copies of a part", selection: $combinedPartsUsesSum) {
                    Text("The higher number: 3 copies").tag(false)
                    Text("Add them up: 5 copies").tag(true)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Parts shared by two instruments")
            } footer: {
                Text("A part like Horn 1/3 is one part for both instruments. Say Horn 1 is set to 3 copies and Horn 3 to 2. If they share a stand, the higher number is enough. If each player needs their own, add them up.")
            }

            Section {
                Toggle("Print double-sided", isOn: $printDefaults.isDoubleSided)
            } header: {
                Text("Paper")
            } footer: {
                Text("Adds a blank back after a part with an odd number of pages, so every copy starts on a new sheet.")
            }

            Section {
                Toggle("Include the score when a song has one", isOn: $printDefaults.includesScore)
                Stepper(value: $printDefaults.scoreCopies, in: 0...50) {
                    Text("\(printDefaults.scoreCopies) copies")
                }
                .disabled(!printDefaults.includesScore)
            } header: {
                Text("Score", comment: "Full orchestral score (partitur)")
            }
        }
        .formStyle(.grouped)
    }
}
