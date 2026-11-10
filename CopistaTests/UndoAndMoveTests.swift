import Testing
import Foundation
import PDFKit
@testable import Copista

@Suite @MainActor struct UndoTests {
    private func imported(_ labelSets: [[String]]) async throws -> (AppModel, UndoManager) {
        let support = try PDFFixtures.directory("support")
        let model = AppModel(settings: SettingsStore(directory: support), corrections: CorrectionStore(directory: support))
        let undoManager = UndoManager()
        // Grouped by hand: there's no event loop here to close each group.
        undoManager.groupsByEvent = false
        model.undoManager = undoManager
        for (index, labels) in labelSets.enumerated() {
            let url = try PDFFixtures.directory().appendingPathComponent("Marsch \(index + 1).pdf")
            try PDFFixtures.scannedPDF(labels: labels, at: url)
            model.importURLs([url])
            await model.waitForImports()
        }
        return (model, undoManager)
    }

    private func edit(_ undoManager: UndoManager, _ change: () -> Void) {
        undoManager.beginUndoGrouping()
        change()
        undoManager.endUndoGrouping()
    }

    private func id(_ model: AppModel, _ key: String) -> UUID {
        model.settings.instruments.first { $0.key == key }!.id
    }

    @Test("Setting an instrument can be undone and redone")
    func undoRedoInstrument() async throws {
        let (model, undoManager) = try await imported([["Tuba", "Horn 1"]])
        let song = model.songs[0]
        let before = song.parts
        let hornPage = try #require(song.parts.first { $0.kind == .instrument(id(model, "horn.1")) }?.pages.first)

        edit(undoManager) { model.setInstrument(id(model, "oboe.1"), forPageIDs: [hornPage.id], inSongID: song.id) }
        let after = model.songs[0].parts
        #expect(after != before)
        #expect(undoManager.undoActionName == String(localized: "Set Instrument", comment: "Undo action name"))

        undoManager.undo()
        #expect(model.songs[0].parts == before)
        undoManager.redo()
        #expect(model.songs[0].parts == after)
    }

    @Test("An undone edit is undone in the saved review too, so it stays undone after a relaunch")
    func undoReachesSavedReview() async throws {
        let (model, undoManager) = try await imported([["Tuba", "Horn 1"]])
        let song = model.songs[0]
        let page = try #require(song.parts.first?.pages.first)
        edit(undoManager) { model.excludePages([page.id], inSongID: song.id) }
        undoManager.undo()

        let hash = try #require(model.sourceDocuments.values.first?.sha256)
        let saved = try #require(model.corrections.detection(forHash: hash, signature: model.settings.catalogSignature, knownInstruments: Set(model.settings.instruments.map(\.id))))
        #expect(!saved.pages.contains { $0.kind == .blank })
    }

    @Test("Edits that change nothing leave nothing to undo")
    func noOpIsNotUndoable() async throws {
        let (model, undoManager) = try await imported([["Tuba"]])
        let song = model.songs[0]
        model.renameSong(song.id, to: song.title)
        model.setCopies([:])
        #expect(!undoManager.canUndo)
    }

    @Test("A removed song comes back, files and all, where it was")
    func undoRemoveSong() async throws {
        let (model, undoManager) = try await imported([["Tuba"], ["Horn 1"]])
        let first = model.songs[0]
        let documentCount = model.sourceDocuments.count

        edit(undoManager) { model.removeSong(first.id) }
        #expect(model.songs.map(\.id) == [model.songs[0].id])
        undoManager.undo()
        #expect(model.songs.first?.id == first.id)
        #expect(model.sourceDocuments.count == documentCount)
        #expect(model.outputPlans[0].plan.musicPageCount == 1, "it still prints")
        undoManager.redo()
        #expect(!model.songs.contains { $0.id == first.id })
    }

    @Test("Undoing an earlier edit leaves a song added since alone")
    func undoKeepsLaterImports() async throws {
        let (model, undoManager) = try await imported([["Tuba", "Horn 1"]])
        let song = model.songs[0]
        edit(undoManager) { model.renameSong(song.id, to: "Festmarsch") }

        let url = try PDFFixtures.directory().appendingPathComponent("Valsen.pdf")
        try PDFFixtures.scannedPDF(labels: ["Oboe"], at: url)
        model.importURLs([url])
        await model.waitForImports()

        undoManager.undo()
        #expect(model.songs.count == 2)
        #expect(model.songs[0].title != "Festmarsch")
    }

    @Test("Copy counts can be undone")
    func undoCopies() async throws {
        let (model, undoManager) = try await imported([["Tuba"]])
        let tuba = id(model, "tuba.1")
        let before = model.printJob.copies[tuba]
        edit(undoManager) { model.setCopies([tuba: 7]) }
        #expect(model.printJob.copies[tuba] == 7)
        undoManager.undo()
        #expect(model.printJob.copies[tuba] == before)
    }

    @Test("Starting over can't be undone")
    func startOverClearsUndo() async throws {
        let (model, undoManager) = try await imported([["Tuba"]])
        edit(undoManager) { model.renameSong(model.songs[0].id, to: "Festmarsch") }
        model.removeAllSongs()
        #expect(!undoManager.canUndo)
    }
}

@Suite @MainActor struct MoveBetweenPartsTests {
    private func imported(labels: [String]) async throws -> AppModel {
        let support = try PDFFixtures.directory("support")
        let url = try PDFFixtures.directory().appendingPathComponent("Marsch.pdf")
        try PDFFixtures.scannedPDF(labels: labels, at: url)
        let model = AppModel(settings: SettingsStore(directory: support), corrections: CorrectionStore(directory: support))
        model.importURLs([url])
        await model.waitForImports()
        return model
    }

    private func pages(_ model: AppModel, _ key: String) -> [Int] {
        let id = model.settings.instruments.first { $0.key == key }!.id
        return model.songs[0].parts.first { $0.kind == .instrument(id) }?.pages.map(\.pageIndex) ?? []
    }

    @Test("A page dropped among another instrument's pages becomes that instrument, where it was dropped")
    func dropIntoOtherPart() async throws {
        let model = try await imported(labels: ["Horn 1", "", "Tuba", ""])
        let song = model.songs[0]
        let all = song.parts.flatMap(\.pages)
        let tubaPage = try #require(all.first { $0.pageIndex == 3 })
        let hornFirst = try #require(all.first { $0.pageIndex == 0 })

        model.movePages([tubaPage.id], nextTo: hornFirst.id, after: false, inSongID: song.id)

        #expect(pages(model, "horn.1") == [3, 0, 1])
        #expect(pages(model, "tuba.1") == [2])
        let moved = model.songs[0].parts.flatMap(\.pages).first { $0.id == tubaPage.id }
        #expect(moved?.source == .manual)
    }

    @Test("Moving a part's last page away leaves no empty part behind, and pages from several parts move together")
    func dropSeveral() async throws {
        let model = try await imported(labels: ["Horn 1", "Tuba", "Oboe"])
        let song = model.songs[0]
        let all = song.parts.flatMap(\.pages)
        let tuba = try #require(all.first { $0.pageIndex == 1 }), oboe = try #require(all.first { $0.pageIndex == 2 })
        let horn = try #require(all.first { $0.pageIndex == 0 })

        model.movePages([oboe.id, tuba.id], nextTo: horn.id, after: true, inSongID: song.id)

        #expect(pages(model, "horn.1") == [0, 2, 1])
        #expect(model.songs[0].parts.count == 1)
    }
}

@Suite @MainActor struct OnePDFPerSongTests {
    @Test("Every song is a PDF of its own, with only its own pages")
    func separateOutputs() async throws {
        let support = try PDFFixtures.directory("support")
        let model = AppModel(settings: SettingsStore(directory: support), corrections: CorrectionStore(directory: support))
        for (name, labels) in [("Festmarsch", ["Tuba", "Horn 1"]), ("Valsen", ["Oboe"])] {
            let url = try PDFFixtures.directory().appendingPathComponent("\(name).pdf")
            try PDFFixtures.scannedPDF(labels: labels, at: url)
            model.importURLs([url])
            await model.waitForImports()
        }

        let outputs = try await model.buildOutputs()
        #expect(outputs.map(\.title) == ["Festmarsch", "Valsen"])
        #expect(outputs.map { PDFDocument(data: $0.data)?.pageCount } == [2, 1])
    }
}
