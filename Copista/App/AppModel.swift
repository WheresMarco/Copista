import Foundation
import Observation
import PDFKit

nonisolated enum WorkflowStep: Sendable {
    case review, copies, print
}

/// The app's single piece of mutable state: imported documents, the songs assembled from them,
/// and the current print job. Owns the whole import → analyze → assemble pipeline; every
/// off-main-actor hop happens inside `runImport`, at each `await` of an actor call
/// (`DocumentAnalyzer`, `Fingerprint.sha256`) — this class itself never leaves the main actor.
@Observable
@MainActor
final class AppModel {
    private(set) var sourceDocuments: [UUID: SourceDocument] = [:]
    private(set) var songs: [Song] = []
    private(set) var isAnalyzing = false
    private(set) var progressLabel = ""
    /// How much of everything being imported has been analyzed, from 0 to 1.
    private(set) var progressFraction = 0.0
    var printJob: PrintJob
    var errorMessage: String?
    var isWelcomeGuidePresented: Bool
    // Here rather than in a view because the menu bar commands reach them too.
    var step = WorkflowStep.review
    var isFileImporterPresented = false

    let settings: SettingsStore
    let corrections: CorrectionStore
    /// The window's, so ⌘Z and ⇧⌘Z in the Edit menu undo and redo edits made here.
    var undoManager: UndoManager?

    private var analysisTask: Task<Void, Never>?
    /// Everything picked in an open panel stays readable only while its security scope is held,
    /// and output is built from the original files, so scopes are kept until the songs are gone.
    private var securityScopedURLs: [URL] = []

    init(settings: SettingsStore = SettingsStore(), corrections: CorrectionStore = CorrectionStore()) {
        self.settings = settings
        self.corrections = corrections
        let defaults = settings.printDefaults
        printJob = PrintJob(copies: [:], scoreCopies: defaults.scoreCopies, isDoubleSided: defaults.isDoubleSided)
        isWelcomeGuidePresented = !settings.hasCompletedWelcome
    }

    /// Puts the print job back to what the settings say, including on songs already here.
    func applyDefaultsToPrintJob() {
        let defaults = settings.printDefaults
        printJob = PrintJob(copies: [:], scoreCopies: defaults.scoreCopies, isDoubleSided: defaults.isDoubleSided)
        applyDefaultCopies()
        setIncludeScoreForAllSongs(defaults.includesScore)
    }

    // MARK: - Import

    /// Queues the files after any import still running, so adding more never loses earlier ones.
    func importURLs(_ urls: [URL]) {
        // A new print job. Nothing can have been edited yet, and the settings may have changed.
        if songs.isEmpty { applyDefaultsToPrintJob() }

        for url in urls where url.startAccessingSecurityScopedResource() {
            securityScopedURLs.append(url)
        }

        let found = expandToPDFs(urls)
        guard !found.separateFiles.isEmpty || !found.folderContents.isEmpty else {
            errorMessage = String(localized: "No PDF files were found there.")
            return
        }
        let alreadyImported = Set(sourceDocuments.values.map(\.url))
        let separateFiles = found.separateFiles.filter { !alreadyImported.contains($0) }
        let folderContents = found.folderContents.filter { !alreadyImported.contains($0) }
        guard !separateFiles.isEmpty || !folderContents.isEmpty else { return }

        let previous = analysisTask
        analysisTask = Task {
            await previous?.value
            await runImport(separateFiles: separateFiles, folderContents: folderContents)
        }
    }

    /// Finishes when every queued import has.
    func waitForImports() async {
        await analysisTask?.value
    }

    /// What was added, kept apart by how it was added: files picked out one by one, and the PDFs
    /// inside folders. Folders are searched all the way down: a library is usually one folder per
    /// song, inside a folder per concert or binder.
    private func expandToPDFs(_ urls: [URL]) -> (separateFiles: [URL], folderContents: [URL]) {
        let fm = FileManager.default
        var separateFiles: [URL] = []
        var folderContents: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let contents = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                folderContents += (contents?.allObjects as? [URL] ?? []).filter { $0.pathExtension.lowercased() == "pdf" }
            } else if url.pathExtension.lowercased() == "pdf" {
                separateFiles.append(url)
            }
        }
        let inOrder: (URL, URL) -> Bool = { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return (separateFiles.sorted(by: inOrder), folderContents.sorted(by: inOrder))
    }

    private func runImport(separateFiles: [URL], folderContents: [URL]) async {
        isAnalyzing = true
        progressFraction = 0
        defer {
            isAnalyzing = false
            progressLabel = ""
        }

        let matcher = NameMatcher(instruments: settings.instruments)
        let grouper = SongGrouper(matcher: matcher)
        // A folder is sorted out by what's in it. Files picked out and added together are a choice
        // someone made, and it means they belong together.
        var drafts = grouper.group(urls: folderContents)
        if separateFiles.count > 1 {
            drafts.insert(grouper.groupAsOneSong(urls: separateFiles), at: 0)
        } else {
            drafts = grouper.group(urls: separateFiles) + drafts
        }
        let documentTotal = max(1, drafts.reduce(0) { $0 + $1.documents.count })
        var documentsDone = 0
        let intelligentMatcher = IntelligentNameMatcher(instruments: settings.instruments)
        let analyzer = DocumentAnalyzer(matcher: matcher, ocr: OCRService(), intelligentMatcher: intelligentMatcher)
        var problems: [String] = []

        for draft in drafts {
            if Task.isCancelled { return }
            progressLabel = String(localized: "Analyzing \(draft.title)…", comment: "Progress label while a song's PDFs are being analyzed")

            var documentPages: [SongAssembler.DocumentPages] = []
            var documentIDs: [UUID] = []
            var skippedSetIDs: [UUID] = []
            // A "complete set" repeats parts that also exist as separate files — but when it's
            // all there is, it's the only copy of them and has to be used.
            let hasOtherParts = draft.documents.contains { $0.role == .parts }

            for doc in draft.documents {
                if Task.isCancelled { return }
                let id = UUID()
                defer {
                    documentsDone += 1
                    progressFraction = Double(documentsDone) / Double(documentTotal)
                }
                let pageCount = PDFDocument(url: doc.url)?.pageCount ?? 0
                let hash = try? await Fingerprint.sha256(of: doc.url)
                let document = SourceDocument(
                    id: id, url: doc.url, bookmarkData: nil, songTitle: draft.title,
                    pageCount: pageCount, sha256: hash, role: doc.role, isExcluded: doc.role == .duplicateSet && hasOtherParts
                )

                if document.isExcluded {
                    sourceDocuments[id] = document
                    skippedSetIDs.append(id)
                    continue
                }

                do {
                    let results = try await classify(
                        doc, id: id, pageCount: pageCount, hash: hash, songTitle: draft.title, analyzer: analyzer,
                        overallProgress: (documentsDone, documentTotal)
                    )
                    documentPages.append(SongAssembler.DocumentPages(documentID: id, results: results))
                    documentIDs.append(id)
                    sourceDocuments[id] = document
                } catch {
                    problems.append("\(doc.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            guard !documentPages.isEmpty else { continue }

            let (parts, issues) = SongAssembler.assemble(songTitle: draft.title, documents: documentPages)
            songs.append(Song(
                id: UUID(), title: draft.title, documentIDs: documentIDs, parts: parts,
                issues: issues + skippedSetIDs.map { .duplicateSet(documentID: $0) }, includeScore: settings.printDefaults.includesScore
            ))
        }

        applyDefaultCopies()
        if !problems.isEmpty {
            errorMessage = problems.joined(separator: "\n")
        }
    }

    /// Per-page results for one document, from the most to the least trustworthy source: the
    /// user's own earlier review or a saved detection, the filename, then actually reading it.
    private func classify(
        _ doc: DocumentDraft, id: UUID, pageCount: Int, hash: String?, songTitle: String, analyzer: DocumentAnalyzer,
        overallProgress: (done: Int, total: Int)
    ) async throws -> [CachedPageResult] {
        let signature = settings.catalogSignature
        if let hash, let cached = corrections.detection(forHash: hash, signature: signature, knownInstruments: Set(settings.instruments.map(\.id))) {
            return cached.pages
        }

        let results: [CachedPageResult]
        if doc.role == .score {
            results = (0..<pageCount).map {
                CachedPageResult(pageIndex: $0, kind: .score, extraInstruments: [], rotation: 0, cropRect: nil, detectedText: doc.url.lastPathComponent, confidence: 0.9, source: .filename)
            }
        } else {
            let (events, continuation) = AsyncStream.makeStream(of: DetectionProgress.self)
            let progressWatcher = Task {
                for await event in events {
                    if case .page(_, let index) = event {
                        progressLabel = String(localized: "Analyzing \(songTitle): page \(index + 1) of \(pageCount)", comment: "Progress label while one PDF's pages are being read")
                        let withinDocument = Double(index) / Double(max(1, pageCount))
                        progressFraction = (Double(overallProgress.done) + withinDocument) / Double(overallProgress.total)
                    }
                }
            }
            defer {
                continuation.finish()
                progressWatcher.cancel()
            }
            let ref = DocumentRef(id: id, url: doc.url, songTitle: songTitle, pageCount: pageCount)
            results = try await analyzer.analyze(ref, progress: continuation)
        }
        if let hash {
            corrections.save(DocumentDetection(sha256: hash, pages: results, catalogSignature: signature))
        }
        return results
    }

    private func applyDefaultCopies() {
        for instrument in settings.instruments where printJob.copies[instrument.id] == nil {
            printJob.copies[instrument.id] = instrument.startingCopies
        }
    }

    // MARK: - Song list

    func removeSong(_ songID: UUID) {
        guard let index = songs.firstIndex(where: { $0.id == songID }) else { return }
        let song = songs[index]
        let documentIDs = song.documentIDs + song.issues.compactMap { issue -> UUID? in
            if case .duplicateSet(let documentID) = issue { return documentID }
            return nil
        }
        let documents = documentIDs.compactMap { sourceDocuments[$0] }
        for documentID in documentIDs { sourceDocuments[documentID] = nil }
        songs.remove(at: index)

        undoManager?.registerUndo(withTarget: self) { model in
            for document in documents { model.sourceDocuments[document.id] = document }
            model.songs.insert(song, at: min(index, model.songs.count))
            model.undoManager?.registerUndo(withTarget: model) { $0.removeSong(songID) }
        }
        undoManager?.setActionName(String(localized: "Remove Song", comment: "Undo action name"))
    }

    func renameSong(_ songID: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        undoable(String(localized: "Rename Song", comment: "Undo action name"), songs: [songID]) {
            guard let index = songs.firstIndex(where: { $0.id == songID }) else { return }
            songs[index].title = trimmed
        }
    }

    func moveSongs(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let moving = offsets.map { songs[$0] }
        var remaining = songs
        for index in offsets.sorted(by: >) {
            remaining.remove(at: index)
        }
        remaining.insert(contentsOf: moving, at: destination - offsets.filter { $0 < destination }.count)
        setSongOrder(remaining.map(\.id))
    }

    /// Songs not in `order`, added since, keep their place after the rest.
    private func setSongOrder(_ order: [UUID]) {
        let previous = songs.map(\.id)
        guard order != previous else { return }
        songs.sort { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
        undoManager?.registerUndo(withTarget: self) { $0.setSongOrder(previous) }
        undoManager?.setActionName(String(localized: "Reorder Songs", comment: "Undo action name"))
    }

    /// Starting over can't be undone: what was added is let go of, files and all.
    func removeAllSongs() {
        undoManager?.removeAllActions()
        analysisTask?.cancel()
        analysisTask = nil
        songs = []
        sourceDocuments = [:]
        for url in securityScopedURLs { url.stopAccessingSecurityScopedResource() }
        securityScopedURLs = []
    }

    // MARK: - Output

    private var documentURLs: [UUID: URL] {
        sourceDocuments.mapValues(\.url)
    }

    /// One plan per song, in the order they're listed. Each song prints and saves on its own.
    var outputPlans: [SongOutput] {
        songs.map { song in
            SongOutput(song: song, plan: OutputPlanner.plan(
                for: song, documentURLs: documentURLs, instruments: settings.instruments,
                job: printJob, combinedPartsUsesSum: settings.combinedPartsUsesSum
            ))
        }
    }

    var printChecks: [PrintCheck] {
        let skipped = sourceDocuments.values.filter(\.isExcluded).reduce(into: [UUID: String]()) { $0[$1.id] = $1.url.lastPathComponent }
        return PrintChecks.run(songs: songs, skippedFileNames: skipped, instruments: settings.instruments, job: printJob, combinedPartsUsesSum: settings.combinedPartsUsesSum)
    }

    func buildOutputData(_ plan: OutputPlan) async throws -> Data {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await OutputBuilder().build(plan, to: tempURL)
        return try Data(contentsOf: tempURL)
    }

    /// A PDF for every song that has something to print.
    func buildOutputs() async throws -> [(title: String, data: Data)] {
        var outputs: [(title: String, data: Data)] = []
        for output in outputPlans where !output.plan.sheets.isEmpty {
            outputs.append((output.song.title, try await buildOutputData(output.plan)))
        }
        return outputs
    }

    // MARK: - Review edits

    // Each edit records how to put the songs it touched back, for Undo. Edits that change nothing
    // record nothing, so Undo never seems to do nothing.

    private func undoable(_ actionName: String, songs songIDs: [UUID], _ edit: () -> Void) {
        let before = songs.filter { songIDs.contains($0.id) }
        edit()
        guard before != songs.filter({ songIDs.contains($0.id) }) else { return }
        registerUndo(actionName, restoring: before)
    }

    /// Undoing records the songs as they are at that point the same way, which is what Redo does.
    private func registerUndo(_ actionName: String, restoring before: [Song]) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            let current = model.songs.filter { song in before.contains { $0.id == song.id } }
            model.registerUndo(actionName, restoring: current)
            for song in before {
                guard let index = model.songs.firstIndex(where: { $0.id == song.id }) else { continue }
                model.songs[index] = song
                model.songEdited(at: index)
            }
        }
        undoManager.setActionName(actionName)
    }

    func setIncludeScore(_ include: Bool, forSongID songID: UUID) {
        undoable(String(localized: "Include Score", comment: "Undo action name"), songs: [songID]) {
            guard let songIndex = songs.firstIndex(where: { $0.id == songID }) else { return }
            songs[songIndex].includeScore = include
        }
    }

    func setIncludeScoreForAllSongs(_ include: Bool) {
        undoable(String(localized: "Include Score", comment: "Undo action name"), songs: songs.map(\.id)) {
            for index in songs.indices { songs[index].includeScore = include }
        }
    }

    /// Copy counts, by instrument. Undone together, as they were set.
    func setCopies(_ changes: [UUID: Int]) {
        let before = changes.keys.reduce(into: [UUID: Int]()) { $0[$1] = printJob.copies[$1] ?? 0 }
        guard before != changes else { return }
        for (id, count) in changes { printJob.copies[id] = count }
        undoManager?.registerUndo(withTarget: self) { $0.setCopies(before) }
        undoManager?.setActionName(String(localized: "Change Copies", comment: "Undo action name"))
    }

    func setScoreCopies(_ count: Int) {
        let before = printJob.scoreCopies
        guard count != before else { return }
        printJob.scoreCopies = count
        undoManager?.registerUndo(withTarget: self) { $0.setScoreCopies(before) }
        undoManager?.setActionName(String(localized: "Change Copies", comment: "Undo action name"))
    }

    /// Marks pages as excluded from the print job by moving them to a `.blank` part (blank parts
    /// are excluded by default in `OutputPlanner`, since they never have a corresponding
    /// instrument to attach copies to).
    func excludePages(_ pageIDs: [UUID], inSongID songID: UUID) {
        undoable(String(localized: "Exclude Pages", comment: "Undo action name"), songs: [songID]) {
            movePages(pageIDs, inSongID: songID, toKind: .blank)
        }
    }

    func markAsScore(_ pageIDs: [UUID], inSongID songID: UUID) {
        undoable(String(localized: "Mark as Score", comment: "Undo action name"), songs: [songID]) {
            movePages(pageIDs, inSongID: songID, toKind: .score)
        }
    }

    /// Pages after these that have no name of their own come along, as they would have if the name
    /// had been read in the first place.
    func setInstrument(_ instrumentID: UUID, forPageIDs pageIDs: [UUID], inSongID songID: UUID) {
        guard let song = songs.first(where: { $0.id == songID }) else { return }
        // Ones already in that part stay where they are in it.
        let alreadyThere = Set(song.parts.filter { $0.kind == .instrument(instrumentID) }.flatMap(\.pages).map(\.id))
        let carried = song.pagesCarried(by: pageIDs).filter { !alreadyThere.contains($0) }
        undoable(String(localized: "Set Instrument", comment: "Undo action name"), songs: [songID]) {
            movePages(pageIDs, inSongID: songID, toKind: .instrument(instrumentID), carrying: carried)
        }
    }

    /// The user has looked at these pages and they're right as they are.
    func confirmPages(_ pageIDs: [UUID], inSongID songID: UUID) {
        undoable(String(localized: "Confirm Pages", comment: "Undo action name"), songs: [songID]) {
            editPages(pageIDs, inSongID: songID) { page in
                page.source = .manual
                page.confidence = 1
            }
        }
    }

    /// Reorders pages within their part: the part of `targetID`, so a page dropped on another
    /// part's page stays where it was.
    func reorderPages(_ pageIDs: [UUID], relativeTo targetID: UUID, after: Bool, inSongID songID: UUID) {
        undoable(String(localized: "Reorder Pages", comment: "Undo action name"), songs: [songID]) {
            reorderPages(inPartContaining: targetID, inSongID: songID) { pages in
                pages.moving(Set(pageIDs), relativeTo: targetID, after: after)
            }
        }
    }

    /// One step earlier or later within their part. Pages from other parts are left out of it.
    func shiftPages(_ pageIDs: [UUID], later: Bool, inSongID songID: UUID) {
        guard let first = pageIDs.first else { return }
        undoable(String(localized: "Reorder Pages", comment: "Undo action name"), songs: [songID]) {
            reorderPages(inPartContaining: first, inSongID: songID) { $0.shifting(Set(pageIDs), later: later) }
        }
    }

    /// Pages dropped next to `targetID`, in the part that page is in. From that same part it's
    /// only a new order; from another, the pages become that part's instrument too, as someone
    /// who dragged them there means. In the order given, which is the order they're shown in.
    func movePages(_ pageIDs: [UUID], nextTo targetID: UUID, after: Bool, inSongID songID: UUID) {
        guard let song = songs.first(where: { $0.id == songID }),
              let target = song.parts.first(where: { $0.pages.contains { $0.id == targetID } }),
              !pageIDs.contains(targetID)
        else { return }
        if pageIDs.allSatisfy({ id in target.pages.contains { $0.id == id } }) {
            reorderPages(pageIDs, relativeTo: targetID, after: after, inSongID: songID)
            return
        }
        undoable(String(localized: "Move Pages", comment: "Undo action name"), songs: [songID]) {
            guard let songIndex = songs.firstIndex(where: { $0.id == songID }) else { return }
            let allPages = songs[songIndex].parts.flatMap(\.pages)
            var moved = pageIDs.compactMap { id in allPages.first { $0.id == id } }
            for index in moved.indices {
                moved[index].source = .manual
                moved[index].confidence = 1
            }
            for partIndex in songs[songIndex].parts.indices {
                songs[songIndex].parts[partIndex].pages.removeAll { pageIDs.contains($0.id) }
            }
            guard let partIndex = songs[songIndex].parts.firstIndex(where: { $0.id == target.id }),
                  let targetIndex = songs[songIndex].parts[partIndex].pages.firstIndex(where: { $0.id == targetID })
            else { return }
            songs[songIndex].parts[partIndex].pages.insert(contentsOf: moved, at: after ? targetIndex + 1 : targetIndex)
            songs[songIndex].parts.removeAll { $0.pages.isEmpty }
            songEdited(at: songIndex)
        }
    }

    private func reorderPages(inPartContaining pageID: UUID, inSongID songID: UUID, _ reorder: ([PageItem]) -> [PageItem]) {
        guard let songIndex = songs.firstIndex(where: { $0.id == songID }),
              let partIndex = songs[songIndex].parts.firstIndex(where: { $0.pages.contains { $0.id == pageID } })
        else { return }
        let reordered = reorder(songs[songIndex].parts[partIndex].pages)
        guard reordered.map(\.id) != songs[songIndex].parts[partIndex].pages.map(\.id) else { return }
        songs[songIndex].parts[partIndex].pages = reordered
        songEdited(at: songIndex)
    }

    func rotatePages(_ pageIDs: [UUID], inSongID songID: UUID) {
        undoable(String(localized: "Rotate Pages", comment: "Undo action name"), songs: [songID]) {
            editPages(pageIDs, inSongID: songID) { page in
                page.rotation = SheetLayout.quarter(page.rotation + 90)
                page.source = .manual
            }
        }
    }

    /// Assigns a page and the ones after it in the same part, for a multi-page part that was
    /// taken for the part before it or wasn't recognized at all.
    func setInstrument(_ instrumentID: UUID, fromPageID pageID: UUID, inSongID songID: UUID) {
        guard let song = songs.first(where: { $0.id == songID }),
              let part = song.parts.first(where: { $0.pages.contains { $0.id == pageID } }),
              let start = part.pages.firstIndex(where: { $0.id == pageID })
        else { return }
        undoable(String(localized: "Set Instrument", comment: "Undo action name"), songs: [songID]) {
            movePages(part.pages[start...].map(\.id), inSongID: songID, toKind: .instrument(instrumentID))
        }
    }

    private func editPages(_ pageIDs: [UUID], inSongID songID: UUID, _ edit: (inout PageItem) -> Void) {
        guard let songIndex = songs.firstIndex(where: { $0.id == songID }) else { return }
        for partIndex in songs[songIndex].parts.indices {
            for pageIndex in songs[songIndex].parts[partIndex].pages.indices
            where pageIDs.contains(songs[songIndex].parts[partIndex].pages[pageIndex].id) {
                edit(&songs[songIndex].parts[partIndex].pages[pageIndex])
            }
        }
        songEdited(at: songIndex)
    }

    /// Removes pages from whichever parts currently hold them and adds them to a part of the
    /// given kind within the same song, creating that part if it doesn't exist yet. Pages keep
    /// their document order in the target part. Parts left empty by the move are dropped.
    /// `carried` pages move too, but nobody has looked at them, so they stay what they were.
    private func movePages(_ pageIDs: [UUID], inSongID songID: UUID, toKind kind: PartKind, carrying carried: [UUID] = []) {
        guard let songIndex = songs.firstIndex(where: { $0.id == songID }) else { return }
        let moving = Set(pageIDs + carried)
        var moved: [PageItem] = []
        for partIndex in songs[songIndex].parts.indices {
            let pages = songs[songIndex].parts[partIndex].pages
            moved += pages.filter { moving.contains($0.id) }
            songs[songIndex].parts[partIndex].pages = pages.filter { !moving.contains($0.id) }
        }
        guard !moved.isEmpty else { return }
        for index in moved.indices where pageIDs.contains(moved[index].id) {
            moved[index].source = .manual
            moved[index].confidence = 1
        }

        songs[songIndex].parts.removeAll { $0.pages.isEmpty }

        let documentOrder = songs[songIndex].documentIDs
        let inDocumentOrder: (PageItem, PageItem) -> Bool = { a, b in
            if a.documentID != b.documentID {
                return (documentOrder.firstIndex(of: a.documentID) ?? 0) < (documentOrder.firstIndex(of: b.documentID) ?? 0)
            }
            return a.pageIndex < b.pageIndex
        }
        if let targetIndex = songs[songIndex].parts.firstIndex(where: { $0.kind == kind }) {
            // Each page goes in where the file has it, without re-sorting what's already there:
            // that part's order may be one the user has chosen.
            for page in moved.sorted(by: inDocumentOrder) {
                let pages = songs[songIndex].parts[targetIndex].pages
                let index = pages.firstIndex { inDocumentOrder(page, $0) } ?? pages.count
                songs[songIndex].parts[targetIndex].pages.insert(page, at: index)
            }
        } else {
            songs[songIndex].parts.append(Part(id: UUID(), songTitle: songs[songIndex].title, kind: kind, pages: moved.sorted(by: inDocumentOrder)))
        }
        songEdited(at: songIndex)
    }

    /// Brings a song's issues up to date and saves the review, so importing the same file again
    /// picks up where the user left off.
    private func songEdited(at songIndex: Int) {
        let song = songs[songIndex]
        let skippedSets = song.issues.filter {
            if case .duplicateSet = $0 { return true }
            return false
        }
        songs[songIndex].issues = SongAssembler.issues(for: song.parts) + skippedSets

        let kept = song.parts.flatMap { part in part.pages.enumerated().map { (part, $0.element, $0.offset) } }
        for documentID in song.documentIDs {
            guard let hash = sourceDocuments[documentID]?.sha256 else { continue }
            let pages = kept.filter { $0.1.documentID == documentID }.map { part, page, position in
                CachedPageResult(
                    pageIndex: page.pageIndex, kind: part.kind, extraInstruments: part.extraInstruments, rotation: page.rotation,
                    cropRect: page.cropRect, detectedText: page.detectedText, confidence: page.confidence, source: page.source,
                    partPosition: position
                )
            }
            corrections.save(DocumentDetection(sha256: hash, pages: pages, catalogSignature: settings.catalogSignature))
        }
    }
}
