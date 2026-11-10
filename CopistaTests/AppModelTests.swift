import Testing
import Foundation
import AppKit
import PDFKit
@testable import Copista

/// The whole app minus the windows: import real files, make the edits a user would make, and
/// count what actually comes out in the print-ready PDF.
@Suite @MainActor struct AppModelTests {

    private func makeModel(in directory: URL? = nil) throws -> AppModel {
        let directory = try directory ?? PDFFixtures.directory("support")
        return AppModel(settings: SettingsStore(directory: directory), corrections: CorrectionStore(directory: directory))
    }

    private func imported(_ urls: [URL], into model: AppModel) async {
        model.importURLs(urls)
        await model.waitForImports()
    }

    private func id(_ model: AppModel, _ key: String) -> UUID {
        model.settings.instruments.first { $0.key == key }!.id
    }

    private func printedPageCount(_ model: AppModel) async throws -> Int {
        try await model.buildOutputs().reduce(0) { $0 + (PDFDocument(data: $1.data)?.pageCount ?? 0) }
    }

    /// A folder laid out like the real library: one PDF per part, one song per folder.
    private func songFolder(_ title: String, parts: [String], in parent: URL) throws -> URL {
        let folder = parent.appendingPathComponent(title, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for part in parts {
            try PDFFixtures.scannedPDF(labels: [part], at: folder.appendingPathComponent("\(title) - \(part).pdf"))
        }
        return folder
    }

    @Test("A library folder is searched recursively and prints one copy per part")
    func nestedFolderImportPrints() async throws {
        let library = try PDFFixtures.directory("Konsert")
        _ = try songFolder("Marsch", parts: ["Klarinett 1", "Klarinett 2", "Tuba"], in: library)
        _ = try songFolder("Vals", parts: ["Klarinett 1", "Horn 1", "Tuba"], in: library)

        let model = try makeModel()
        await imported([library], into: model)

        #expect(model.songs.map(\.title) == ["Marsch", "Vals"])
        #expect(try await printedPageCount(model) == 6)
    }

    @Test("A multi-part scanned PDF prints each part with its own copy count")
    func scannedDocumentRespectsCopies() async throws {
        let url = try PDFFixtures.directory().appendingPathComponent("Festmarsch.pdf")
        try PDFFixtures.scannedPDF(labels: ["Klarinett 1", "Klarinett 2", "Trombon 1"], at: url)

        let model = try makeModel()
        await imported([url], into: model)
        model.printJob.copies[id(model, "clarinet.bb.1")] = 4
        model.printJob.copies[id(model, "clarinet.bb.2")] = 2
        model.printJob.copies[id(model, "trombone.1")] = 0

        #expect(try await printedPageCount(model) == 6)
    }

    @Test("After a relaunch, a saved detection still resolves to instruments and prints")
    func savedDetectionSurvivesRelaunch() async throws {
        let support = try PDFFixtures.directory("support")
        let url = try PDFFixtures.directory().appendingPathComponent("Festmarsch.pdf")
        try PDFFixtures.scannedPDF(labels: ["Klarinett 1", "Tuba"], at: url)

        await imported([url], into: try makeModel(in: support))

        let relaunched = try makeModel(in: support)
        await imported([url], into: relaunched)
        #expect(relaunched.songs.first?.parts.count == 2)
        #expect(try await printedPageCount(relaunched) == 2)
    }

    @Test("A detection that names an instrument which no longer exists is redone, not trusted")
    func staleDetectionIsDiscarded() async throws {
        let support = try PDFFixtures.directory("support")
        let url = try PDFFixtures.directory().appendingPathComponent("Festmarsch.pdf")
        try PDFFixtures.scannedPDF(labels: ["Tuba"], at: url)
        let hash = try await Fingerprint.sha256(of: url)

        let corrections = CorrectionStore(directory: support)
        let settings = SettingsStore(directory: support)
        let orphan = CachedPageResult(pageIndex: 0, kind: .instrument(UUID()), extraInstruments: [], rotation: 0, cropRect: nil, detectedText: nil, confidence: 0.9, source: .ocr)
        corrections.save(DocumentDetection(sha256: hash, pages: [orphan], catalogSignature: settings.catalogSignature))

        let model = AppModel(settings: settings, corrections: corrections)
        await imported([url], into: model)
        #expect(model.songs.first?.parts.first?.kind == .instrument(id(model, "tuba.1")))
    }

    @Test("A manual correction is still there the next time the file is imported")
    func manualCorrectionPersists() async throws {
        let support = try PDFFixtures.directory("support")
        let url = try PDFFixtures.directory().appendingPathComponent("Festmarsch.pdf")
        try PDFFixtures.scannedPDF(labels: ["Klarinett 1", "Tuba"], at: url)

        let first = try makeModel(in: support)
        await imported([url], into: first)
        let song = try #require(first.songs.first)
        let page = try #require(song.parts.first { $0.kind == .instrument(id(first, "tuba.1")) }?.pages.first)
        first.setInstrument(id(first, "horn.1"), forPageIDs: [page.id], inSongID: song.id)

        let second = try makeModel(in: support)
        await imported([url], into: second)
        let kinds = second.songs.first?.parts.map(\.kind) ?? []
        #expect(kinds.contains(.instrument(id(second, "horn.1"))))
        #expect(!kinds.contains(.instrument(id(second, "tuba.1"))))
    }

    @Test("Remembering an alias applies when the same file is imported again")
    func rememberedAliasInvalidatesSavedDetection() async throws {
        let support = try PDFFixtures.directory("support")
        let url = try PDFFixtures.directory().appendingPathComponent("Festmarsch.pdf")
        try PDFFixtures.scannedPDF(labels: ["Bombardon"], at: url)

        let first = try makeModel(in: support)
        await imported([url], into: first)
        #expect(first.songs.first?.parts.first?.kind == .unassigned)
        first.settings.addAlias("Bombardon", toInstrumentID: id(first, "horn.1"))

        let second = try makeModel(in: support)
        await imported([url], into: second)
        #expect(second.songs.first?.parts.first?.kind == .instrument(id(second, "horn.1")))
    }

    @Test("Importing the same files twice doesn't print them twice")
    func reimportIsIgnored() async throws {
        let url = try PDFFixtures.directory().appendingPathComponent("Festmarsch.pdf")
        try PDFFixtures.scannedPDF(labels: ["Tuba"], at: url)

        let model = try makeModel()
        await imported([url], into: model)
        await imported([url], into: model)
        #expect(model.songs.count == 1)
        #expect(try await printedPageCount(model) == 1)
    }

    @Test("Two songs with the same title both print")
    func sameTitleSongsBothPrint() async throws {
        let one = try PDFFixtures.directory().appendingPathComponent("Marsch.pdf")
        let other = try PDFFixtures.directory().appendingPathComponent("Marsch.pdf")
        try PDFFixtures.scannedPDF(labels: ["Tuba"], at: one)
        try PDFFixtures.scannedPDF(labels: ["Horn 1", "Horn 2"], at: other)

        let model = try makeModel()
        await imported([one], into: model)
        await imported([other], into: model)
        #expect(model.songs.count == 2)
        #expect(try await printedPageCount(model) == 3)
    }

    @Test("A second import while one is running adds to it rather than cancelling it")
    func secondImportDoesNotCancelFirst() async throws {
        let one = try PDFFixtures.directory().appendingPathComponent("Marsch.pdf")
        let other = try PDFFixtures.directory().appendingPathComponent("Vals.pdf")
        try PDFFixtures.scannedPDF(labels: ["Tuba"], at: one)
        try PDFFixtures.scannedPDF(labels: ["Tuba"], at: other)

        let model = try makeModel()
        model.importURLs([one])
        model.importURLs([other])
        await model.waitForImports()
        #expect(model.songs.map(\.title) == ["Marsch", "Vals"])
    }

    @Test("A file named as a score is all score, however its pages read")
    func scoreFileIsAllScore() async throws {
        let folder = try PDFFixtures.directory("Marsch")
        try PDFFixtures.scannedPDF(labels: ["Klarinett 1", "Horn 1", "Tuba", "Flöjt 1", "Oboe"], at: folder.appendingPathComponent("Marsch - Score.pdf"))
        try PDFFixtures.scannedPDF(labels: ["Tuba"], at: folder.appendingPathComponent("Marsch - Tuba.pdf"))
        try PDFFixtures.scannedPDF(labels: ["Horn 1"], at: folder.appendingPathComponent("Marsch - Horn 1.pdf"))

        let model = try makeModel()
        await imported([folder], into: model)
        let song = try #require(model.songs.first)
        #expect(song.scorePart?.pages.count == 5)
        #expect(try await printedPageCount(model) == 2, "the score stays out until it's asked for")

        model.setIncludeScoreForAllSongs(true)
        model.printJob.scoreCopies = 2
        #expect(try await printedPageCount(model) == 12)
    }

    @Test("A complete set is used when it's the only source of the parts")
    func loneSetIsNotSkipped() async throws {
        let folder = try PDFFixtures.directory("Marsch")
        try PDFFixtures.scannedPDF(labels: ["Klarinett 1", "Tuba"], at: folder.appendingPathComponent("Marsch_Set.pdf"))
        try PDFFixtures.scannedPDF(labels: ["Partitur"], at: folder.appendingPathComponent("Marsch - Score.pdf"))
        try PDFFixtures.scannedPDF(labels: ["Partitur"], at: folder.appendingPathComponent("Marsch - Full Score.pdf"))

        let model = try makeModel()
        await imported([folder], into: model)
        #expect(try await printedPageCount(model) == 2)
    }

    @Test("Double-sided printing starts every copy on the front of a sheet")
    func doubleSidedPadsOddParts() async throws {
        let url = try PDFFixtures.directory().appendingPathComponent("Marsch - Tuba.pdf")
        try PDFFixtures.scannedPDF(labels: ["Tuba", "", "", "Horn 1", ""], at: url)

        let model = try makeModel()
        await imported([url], into: model)
        model.printJob.isDoubleSided = true
        model.printJob.copies[id(model, "tuba.1")] = 2
        model.printJob.copies[id(model, "horn.1")] = 1

        // Tuba: 3 pages + blank, twice. Horn: 2 pages, no blank.
        let plan = model.outputPlans[0].plan
        #expect(plan.sheets.count == 10)
        #expect(plan.musicPageCount == 8)
        #expect(plan.paperCount(isDoubleSided: true) == 5)
        #expect(try await printedPageCount(model) == 10)
    }

    @Test("Moved pages keep their document order within the target part")
    func movedPagesStayInOrder() async throws {
        let url = try PDFFixtures.directory().appendingPathComponent("Marsch.pdf")
        try PDFFixtures.scannedPDF(labels: ["Tuba", "Horn 1", "Tuba"], at: url)

        let model = try makeModel()
        await imported([url], into: model)
        let song = try #require(model.songs.first)
        let tuba = id(model, "tuba.1")
        let horn = try #require(song.parts.first { $0.kind == .instrument(id(model, "horn.1")) }?.pages.first)
        model.setInstrument(tuba, forPageIDs: [horn.id], inSongID: song.id)

        let pages = model.songs[0].parts.filter { $0.kind == .instrument(tuba) }.flatMap(\.pages).map(\.pageIndex)
        #expect(pages.contains(1))
        #expect(model.songs[0].parts.first { $0.kind == .instrument(tuba) }?.pages.map(\.pageIndex) == [0, 1])
    }

    @Test("Settings survive a relaunch, including the combined-parts toggle")
    func settingsPersist() throws {
        let support = try PDFFixtures.directory("support")
        let first = SettingsStore(directory: support)
        first.combinedPartsUsesSum = true

        let second = SettingsStore(directory: support)
        #expect(second.combinedPartsUsesSum)
    }

    @Test("A settings file from when there were presets still opens")
    func settingsWithPresetsStillOpen() throws {
        let support = try PDFFixtures.directory("support")
        let first = SettingsStore(directory: support)
        first.combinedPartsUsesSum = true
        let data = try #require(first.exportJSON())
        var file = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        file["copyPresets"] = [["id": UUID().uuidString, "name": "Lilla kåren", "copies": [String]()] as [String: Any]]
        try JSONSerialization.data(withJSONObject: file).write(to: support.appendingPathComponent("settings.json"))

        #expect(SettingsStore(directory: support).combinedPartsUsesSum)
    }

    @Test("Instrument IDs are the same on every launch and after a reset")
    func instrumentIDsAreStable() throws {
        let first = InstrumentCatalog.seedInstruments().map(\.id)
        #expect(first == InstrumentCatalog.seedInstruments().map(\.id))
        #expect(Set(first).count == first.count)

        let store = SettingsStore(directory: try PDFFixtures.directory("support"))
        store.resetToSeedDefaults()
        #expect(store.instruments.map(\.id) == first)
    }

    @Test("Instruments not included by default start at 0 copies")
    func includedByDefaultIsHonoured() async throws {
        let url = try PDFFixtures.directory().appendingPathComponent("Marsch.pdf")
        try PDFFixtures.scannedPDF(labels: ["Horn 1", "Horn 2"], at: url)

        let model = try makeModel()
        var horn = try #require(model.settings.instruments.first { $0.key == "horn.1" })
        horn.includedByDefault = false
        model.settings.updateInstrument(horn)
        await imported([url], into: model)

        #expect(model.printJob.copies[horn.id] == 0)
        #expect(try await printedPageCount(model) == 1)
    }

    @Test("Preflight names unassigned pages and parts set to 0 copies")
    func preflightReportsProblems() async throws {
        let url = try PDFFixtures.directory().appendingPathComponent("Marsch.pdf")
        try PDFFixtures.scannedPDF(labels: ["Bombardon", "Horn 1"], at: url)

        let model = try makeModel()
        await imported([url], into: model)
        model.printJob.copies[id(model, "horn.1")] = 0

        let checks = model.printChecks
        #expect(checks.filter { $0.severity == .mustFix }.count == 1)
        #expect(checks.filter { $0.severity == .note }.count == 1)
    }

    @Test("Output pages come out upright whatever the source's /Rotate", arguments: [0, 90, 180, 270])
    func outputIsUpright(rotation: Int) async throws {
        let folder = try PDFFixtures.directory()
        let url = folder.appendingPathComponent("Marsch - Tuba.pdf")
        try PDFFixtures.topBandPDF(at: url, rotation: rotation)

        let plan = OutputPlan(sheets: [SheetSpec(documentURL: url, pageIndex: 0, rotation: 0, cropRect: nil)])
        let output = folder.appendingPathComponent("output.pdf")
        try await OutputBuilder().build(plan, to: output)

        let ink = try PDFFixtures.topAndBottomInk(ofPage: 0, in: output)
        // Not solid black: about half of the sheet's top 5% is its white printing margin.
        #expect(ink.top > 0.3, "top should be inked, got \(ink.top)")
        #expect(ink.bottom < 0.05, "bottom should be white, got \(ink.bottom)")
    }

    @Test("A user's extra rotation turns a sideways scan upright on paper")
    func extraRotationIsApplied() async throws {
        let folder = try PDFFixtures.directory()
        let url = folder.appendingPathComponent("sideways.pdf")
        // No /Rotate flag, but the band is on the left: needs a clockwise quarter turn.
        try PDFFixtures.topBandPDF(at: url, rotation: 90)
        let flagless = folder.appendingPathComponent("flagless.pdf")
        let document = try #require(PDFDocument(url: url))
        document.page(at: 0)?.rotation = 0
        #expect(document.write(to: flagless))

        let plan = OutputPlan(sheets: [SheetSpec(documentURL: flagless, pageIndex: 0, rotation: 90, cropRect: nil)])
        let output = folder.appendingPathComponent("output.pdf")
        try await OutputBuilder().build(plan, to: output)

        let ink = try PDFFixtures.topAndBottomInk(ofPage: 0, in: output)
        #expect(ink.top > 0.3)
        #expect(ink.bottom < 0.05)
    }

    @Test("The print operation sends every page to the printer", .timeLimit(.minutes(1)))
    func printOperationOutputsAllPages() async throws {
        let folder = try PDFFixtures.directory()
        let url = folder.appendingPathComponent("Marsch.pdf")
        try PDFFixtures.scannedPDF(labels: ["Tuba", "Horn 1"], at: url)
        let model = try makeModel()
        await imported([url], into: model)
        model.printJob.copies[id(model, "tuba.1")] = 3

        let document = PDFDocument(data: try await model.buildOutputData(model.outputPlans[0].plan))
        let destination = folder.appendingPathComponent("printed.pdf")
        let info = NSPrintInfo(dictionary: [.jobSavingURL: destination])
        info.jobDisposition = .save

        let operation = try #require(PrintService.operation(for: document, printInfo: info))
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        #expect(operation.run())
        #expect(PDFDocument(url: destination)?.pageCount == 4)
    }
}
