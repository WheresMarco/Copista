import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @State private var selectedSongID: UUID?
    @State private var isDropTargeted = false
    @State private var wantsImporterAfterGuide = false
    @State private var renamingSong: Song?
    @State private var newTitle = ""

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $selectedSongID) {
                if !model.songs.isEmpty {
                    Section {
                        ForEach(model.songs) { song in
                            SongRow(song: song)
                                .tag(song.id)
                                .contextMenu {
                                    Button("Rename…") { beginRenaming(song) }
                                    Button("Remove from Print Job") { model.removeSong(song.id) }
                                }
                        }
                        .onMove { model.moveSongs(fromOffsets: $0, toOffset: $1) }
                    } header: {
                        Text("Songs", comment: "Sidebar list of imported songs")
                    }
                }
            }
            .onDeleteCommand {
                if let selectedSongID { model.removeSong(selectedSongID) }
            }
            .overlay {
                if model.songs.isEmpty && !model.isAnalyzing { sidebarEmptyState }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if model.isAnalyzing {
                        AnalysisProgressCard(label: model.progressLabel, fraction: model.progressFraction)
                    }
                    Button {
                        model.isFileImporterPresented = true
                    } label: {
                        Label("Add Files…", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240)
        } detail: {
            if model.songs.isEmpty {
                ImportDropView(isDropTargeted: isDropTargeted) { model.isFileImporterPresented = true }
            } else {
                Group {
                    switch model.step {
                    case .review:
                        if let song = selectedSong {
                            ReviewView(song: song)
                        } else {
                            ContentUnavailableView("Select a song", systemImage: "music.note.list")
                                .frame(maxHeight: .infinity)
                        }
                    case .copies:
                        CopiesView()
                    case .print:
                        PrintView(selectedSongID: selectedSongID) { songID in
                            selectedSongID = songID
                            model.step = .review
                        }
                    }
                }
                .frame(minWidth: 720)
            }
        }
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .toolbar {
            // Kept as stable ToolbarItems whose state changes, rather than conditionally
            // adding/removing the items themselves — SwiftUI's toolbar builder on macOS doesn't
            // reliably re-render when whole items appear and disappear.
            ToolbarItem(placement: .principal) {
                Picker("Step", selection: $model.step) {
                    Text("Review").tag(WorkflowStep.review)
                    Text("Copies").tag(WorkflowStep.copies)
                    Text("Print").tag(WorkflowStep.print)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(model.songs.isEmpty)
            }
            ToolbarItem {
                Button {
                    model.removeAllSongs()
                    model.step = .review
                } label: {
                    Label("Start Over", systemImage: "arrow.counterclockwise")
                }
                .disabled(model.songs.isEmpty && !model.isAnalyzing)
            }
        }
        .sheet(isPresented: $model.isWelcomeGuidePresented, onDismiss: {
            // After the sheet has gone: an open panel can't appear over one that's still closing.
            if wantsImporterAfterGuide {
                wantsImporterAfterGuide = false
                model.isFileImporterPresented = true
            }
        }) {
            WelcomeGuideView(settings: model.settings) { wantsToAddFiles in
                wantsImporterAfterGuide = wantsToAddFiles
            }
        }
        // The only file importer in the window: SwiftUI doesn't reliably present a second one
        // further down the same hierarchy, so `ImportDropView` asks for this one instead.
        .fileImporter(isPresented: $model.isFileImporterPresented, allowedContentTypes: [.pdf, .folder], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.importURLs(urls)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importURLs(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .alert(
            "Some files couldn't be used",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }),
            presenting: model.errorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .alert("Rename Song", isPresented: Binding(get: { renamingSong != nil }, set: { if !$0 { renamingSong = nil } })) {
            TextField("Name", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let renamingSong { model.renameSong(renamingSong.id, to: newTitle) }
            }
        }
        .onChange(of: undoManager, initial: true) { _, undoManager in model.undoManager = undoManager }
        .onChange(of: model.songs.map(\.id), initial: true) { _, ids in
            if selectedSongID == nil || !ids.contains(selectedSongID!) { selectedSongID = ids.first }
        }
    }

    private func beginRenaming(_ song: Song) {
        newTitle = song.title
        renamingSong = song
    }

    private var windowTitle: String {
        guard !model.songs.isEmpty else { return "Copista" }
        switch model.step {
        case .review: return selectedSong?.title ?? "Copista"
        case .copies: return String(localized: "Copies")
        case .print: return String(localized: "Print")
        }
    }

    private var windowSubtitle: String {
        guard !model.songs.isEmpty else { return "" }
        if model.step == .review {
            return selectedSong?.summary ?? ""
        }
        return String(localized: "\(model.songs.count) songs")
    }

    private var sidebarEmptyState: some View {
        VStack(spacing: 10) {
            SheetStackIllustration(size: CGSize(width: 42, height: 56))
            Text("No songs yet")
                .brandHeadingFont(.headline)
            Text("Songs you add show up here, in the order they'll print. Drag to reorder them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Welcome Guide") { model.isWelcomeGuidePresented = true }
                .buttonStyle(.link)
                .font(.callout)
        }
        .padding()
    }

    private var selectedSong: Song? {
        model.songs.first { $0.id == selectedSongID }
    }
}

private struct SongRow: View {
    let song: Song

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .lineLimit(1)
                Text(song.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            SongStatusBadge(song: song)
        }
        .padding(.vertical, 2)
    }
}

/// How far along analysis is. In the sidebar rather than the toolbar: a long song title has room
/// here, and it isn't squeezed into a toolbar item's capsule.
private struct AnalysisProgressCard: View {
    let label: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.callout)
                .monospacedDigit()
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(.brandInk)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// How much is left to do in a song: red for pages that won't print, orange for ones to check.
private struct SongStatusBadge: View {
    let song: Song

    var body: some View {
        if song.mustFixCount > 0 {
            badge(count: song.mustFixCount, severity: .mustFix)
                .help("Pages with no instrument. They won't print.")
        } else if song.checkCount > 0 {
            badge(count: song.checkCount, severity: .check)
                .help("Pages that need checking. They will print, but may be wrong.")
        }
    }

    private func badge(count: Int, severity: ReviewItem.Severity) -> some View {
        Text("\(count)")
            .font(.caption.bold().monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(severity.color, in: Capsule())
            .accessibilityLabel(Text("Has issues"))
            .accessibilityValue(Text("\(count)"))
    }
}
