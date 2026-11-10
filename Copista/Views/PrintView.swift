import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

struct PrintView: View {
    /// The song shown in the preview: the one selected in the sidebar.
    let selectedSongID: UUID?
    let onReview: (UUID) -> Void

    @Environment(AppModel.self) private var model
    @State private var previewDocument: PDFDocument?
    @State private var isBuilding = false
    @State private var isSavePanelPresented = false
    @State private var pendingExport: (title: String, data: Data)?

    /// Everything on this step that changes what the preview should show. The copies and songs
    /// can only change on other steps, which rebuilds this view anyway.
    private struct PreviewInputs: Hashable {
        let songID: UUID?
        let isDoubleSided: Bool
    }

    private var previewedOutput: SongOutput? {
        let outputs = model.outputPlans
        return outputs.first { $0.song.id == selectedSongID } ?? outputs.first
    }

    /// The songs that have something to print. Each is a PDF of its own.
    private var printableCount: Int {
        model.outputPlans.filter { !$0.plan.sheets.isEmpty }.count
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 12) {
            VStack(spacing: 10) {
                HStack {
                    summary
                    Spacer()
                    Toggle("Double-sided", isOn: $model.printJob.isDoubleSided)
                        .toggleStyle(.checkbox)
                        .help("Adds a blank back after a part with an odd number of pages, so each copy starts on a new sheet. Turn on double-sided printing in the print dialog too.")
                }
                checksList
            }
            .padding([.horizontal, .top])

            VStack(alignment: .leading, spacing: 6) {
                if let song = previewedOutput?.song {
                    HStack(alignment: .firstTextBaseline) {
                        Text(song.title).font(.headline)
                        if model.songs.count > 1 {
                            Text("Select a song in the sidebar to see it here.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal)
                }
                Group {
                    if let previewDocument, previewDocument.pageCount > 0 {
                        PDFKitRepresentable(document: previewDocument)
                    } else if isBuilding {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView(
                            "Nothing to print",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("Give at least one part some copies in the Copies step.")
                        )
                    }
                }
            }

            HStack {
                Button(printableCount > 1 ? "Save PDFs…" : "Save PDF…") { savePDFs() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Open in Preview") { openInPreview() }
                Button("Print…") { printAll() }
                    .keyboardShortcut("p", modifiers: .command)
                    .help("Each song is sent to the printer as its own job.")
                Spacer()
                if isBuilding { ProgressView().controlSize(.small) }
            }
            .disabled(printableCount == 0)
            .padding()
        }
        .task(id: PreviewInputs(songID: previewedOutput?.song.id, isDoubleSided: model.printJob.isDoubleSided)) {
            await buildPreview()
        }
        .fileExporter(
            isPresented: $isSavePanelPresented,
            document: pendingExport.map { PDFExportDocument(data: $0.data) },
            contentType: .pdf,
            defaultFilename: pendingExport.map { Self.safeFilename($0.title) }
        ) { result in
            if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
        }
    }

    private var summary: some View {
        let plans = model.outputPlans.map(\.plan)
        let pages = plans.reduce(0) { $0 + $1.musicPageCount }
        let paper = plans.reduce(0) { $0 + $1.paperCount(isDoubleSided: model.printJob.isDoubleSided) }
        return VStack(alignment: .leading, spacing: 2) {
            Text("Pages of music: \(pages) · Sheets of paper: \(paper)")
            if printableCount > 1 {
                Text("\(printableCount) songs, each a PDF of its own")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// Nothing goes to the printer blind: anything that will come out differently from what
    /// someone might assume is listed up front.
    @ViewBuilder
    private var checksList: some View {
        let checks = model.printChecks
        if !checks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(checks) { check in
                            HStack(alignment: .firstTextBaseline) {
                                Label {
                                    Text(check.message)
                                } icon: {
                                    Image(systemName: check.severity.systemImage)
                                        .foregroundStyle(check.severity.color)
                                }
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if let songID = check.songID {
                                    Button("Show") { onReview(songID) }
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 110)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private static func safeFilename(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    private func buildPreview() async {
        guard let plan = previewedOutput?.plan else {
            previewDocument = nil
            return
        }
        isBuilding = true
        defer { isBuilding = false }
        do {
            let data = try await model.buildOutputData(plan)
            try Task.checkCancellation()
            previewDocument = PDFDocument(data: data)
        } catch is CancellationError {
            // Superseded by a newer build.
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    /// One song: a save panel for its file. Several: a folder, with a file per song in it.
    private func savePDFs() {
        if printableCount == 1 {
            perform { model in
                pendingExport = try await model.buildOutputs().first
                isSavePanelPresented = pendingExport != nil
            }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Save Here", comment: "Button in the folder picker for saving one PDF per song")
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        perform { model in
            let isScoped = folder.startAccessingSecurityScopedResource()
            defer { if isScoped { folder.stopAccessingSecurityScopedResource() } }
            for output in try await model.buildOutputs() {
                let file = folder.appendingPathComponent(Self.safeFilename(output.title)).appendingPathExtension("pdf")
                try output.data.write(to: file, options: .atomic)
            }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    private func openInPreview() {
        perform { model in
            for output in try await model.buildOutputs() {
                _ = try PrintService.openInPreview(data: output.data, suggestedName: Self.safeFilename(output.title))
            }
        }
    }

    private func printAll() {
        perform { model in
            // Built fresh rather than reusing the preview, which may still be catching up.
            let documents = try await model.buildOutputs().compactMap { output in
                PDFDocument(data: output.data).map { (title: output.title, document: $0) }
            }
            try PrintService.print(documents)
        }
    }

    private func perform(_ work: @escaping @MainActor (AppModel) async throws -> Void) {
        let model = model
        Task {
            isBuilding = true
            defer { isBuilding = false }
            do {
                try await work(model)
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct PDFKitRepresentable: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document { nsView.document = document }
    }
}

private struct PDFExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
