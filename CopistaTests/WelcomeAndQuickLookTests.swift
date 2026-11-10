import Testing
import Foundation
import PDFKit
@testable import Copista

@Suite @MainActor struct WelcomeSettingsTests {
    private func support() throws -> URL { try PDFFixtures.directory("support") }

    @Test("A fresh install shows the guide; once done, it doesn't come back")
    func guideShowsOnce() throws {
        let directory = try support()
        let first = SettingsStore(directory: directory)
        #expect(AppModel(settings: first, corrections: CorrectionStore(directory: directory)).isWelcomeGuidePresented)
        first.hasCompletedWelcome = true

        let second = SettingsStore(directory: directory)
        #expect(!AppModel(settings: second, corrections: CorrectionStore(directory: directory)).isWelcomeGuidePresented)
    }

    @Test("A settings file from before the guide existed still loads, and gets the guide")
    func oldSettingsFileLoads() throws {
        let directory = try support()
        let store = SettingsStore(directory: directory)
        store.combinedPartsUsesSum = true
        store.hasCompletedWelcome = true

        let file = directory.appendingPathComponent("settings.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["printDefaults"] = nil
        json["hasCompletedWelcome"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: file)

        let reloaded = SettingsStore(directory: directory)
        #expect(reloaded.combinedPartsUsesSum, "existing settings must survive")
        #expect(!reloaded.hasCompletedWelcome)
        #expect(reloaded.printDefaults == PrintDefaults())
    }

    @Test("Print defaults and default copies survive a relaunch")
    func defaultsPersist() throws {
        let directory = try support()
        let first = SettingsStore(directory: directory)
        let horn = try #require(first.instruments.first { $0.key == "horn.1" })
        first.printDefaults = PrintDefaults(isDoubleSided: true, includesScore: true, scoreCopies: 3)
        first.setDefaultCopies([horn.id: 4])

        let second = SettingsStore(directory: directory)
        #expect(second.printDefaults.isDoubleSided)
        #expect(second.printDefaults.includesScore)
        #expect(second.printDefaults.scoreCopies == 3)
        #expect(second.instruments.first { $0.id == horn.id }?.defaultCopies == 4)
    }

    @Test("Setting copies re-includes an instrument left out before: 0 is what leaves one out now")
    func setDefaultCopiesIncludes() throws {
        let store = SettingsStore(directory: try support())
        var horn = try #require(store.instruments.first { $0.key == "horn.1" })
        horn.includedByDefault = false
        store.updateInstrument(horn)
        #expect(store.instruments.first { $0.id == horn.id }?.startingCopies == 0)

        store.setDefaultCopies([horn.id: 2])
        #expect(store.instruments.first { $0.id == horn.id }?.startingCopies == 2)
    }

    @Test("A new print job starts from the defaults, however they were last changed")
    func newJobUsesDefaults() async throws {
        let directory = try support()
        let settings = SettingsStore(directory: directory)
        let model = AppModel(settings: settings, corrections: CorrectionStore(directory: directory))

        // Changed after the model exists, as from the guide or the Settings window.
        let horn = try #require(settings.instruments.first { $0.key == "horn.1" })
        settings.setDefaultCopies([horn.id: 3])
        settings.printDefaults = PrintDefaults(isDoubleSided: true, includesScore: true, scoreCopies: 2)

        let folder = try PDFFixtures.directory("Marsch")
        try PDFFixtures.scannedPDF(labels: ["Partitur"], at: folder.appendingPathComponent("Marsch - Score.pdf"))
        try PDFFixtures.scannedPDF(labels: ["Horn 1"], at: folder.appendingPathComponent("Marsch - Horn 1.pdf"))
        try PDFFixtures.scannedPDF(labels: ["Horn 2"], at: folder.appendingPathComponent("Marsch - Horn 2.pdf"))
        model.importURLs([folder])
        await model.waitForImports()

        #expect(model.printJob.isDoubleSided)
        #expect(model.printJob.scoreCopies == 2)
        #expect(model.printJob.copies[horn.id] == 3)
        #expect(model.songs.first?.includeScore == true)
    }

    @Test("Adding more songs to a job doesn't undo copies already edited in it")
    func secondImportKeepsEdits() async throws {
        let directory = try support()
        let model = AppModel(settings: SettingsStore(directory: directory), corrections: CorrectionStore(directory: directory))
        let one = try PDFFixtures.directory().appendingPathComponent("Marsch.pdf")
        let other = try PDFFixtures.directory().appendingPathComponent("Vals.pdf")
        try PDFFixtures.scannedPDF(labels: ["Horn 1"], at: one)
        try PDFFixtures.scannedPDF(labels: ["Horn 1"], at: other)

        model.importURLs([one])
        await model.waitForImports()
        let horn = try #require(model.settings.instruments.first { $0.key == "horn.1" })
        model.printJob.copies[horn.id] = 7

        model.importURLs([other])
        await model.waitForImports()
        #expect(model.printJob.copies[horn.id] == 7)
    }

    @Test("Every built-in instrument belongs to a real section")
    func everyInstrumentHasASection() {
        #expect(InstrumentCatalog.seedInstruments().allSatisfy { $0.section != .other })
    }
}

@Suite struct QuickLookFilesTests {
    private func page(_ url: URL, index: Int = 0, rotation: Int = 0, title: String = "Klarinett 1, sida 1") -> QuickLookFiles.Page {
        QuickLookFiles.Page(id: UUID(), documentURL: url, pageIndex: index, rotation: rotation, cropRect: nil, title: title)
    }

    @Test("Each page becomes a one-page PDF, in the order asked for, named for the panel's title")
    func makesOnePagePDFs() async throws {
        let folder = try PDFFixtures.directory()
        let source = folder.appendingPathComponent("Marsch.pdf")
        try PDFFixtures.scannedPDF(labels: ["Horn 1", "Horn 2", "Tuba"], at: source)

        let pages = [page(source, index: 2, title: "Tuba, sida 1"), page(source, index: 0, title: "Horn 1, sida 1")]
        let urls = try await QuickLookFiles.prepare(pages, in: folder.appendingPathComponent("ql"))

        #expect(urls.map(\.lastPathComponent) == ["Tuba, sida 1.pdf", "Horn 1, sida 1.pdf"])
        #expect(urls.allSatisfy { PDFDocument(url: $0)?.pageCount == 1 })
    }

    @Test("A title with a slash can't escape into a subfolder")
    func titleIsSafe() throws {
        let folder = try PDFFixtures.directory()
        let url = QuickLookFiles.url(for: page(folder, title: "Horn 1/3: sida 1"), in: folder)
        #expect(url.lastPathComponent == "Horn 1-3- sida 1.pdf")
    }

    @Test("A rotated page gets a new file showing the rotation, not the old one")
    func rotationMakesNewFile() async throws {
        let folder = try PDFFixtures.directory()
        let source = folder.appendingPathComponent("sideways.pdf")
        try PDFFixtures.topBandPDF(at: source)
        let id = UUID()
        func item(_ rotation: Int) -> QuickLookFiles.Page {
            QuickLookFiles.Page(id: id, documentURL: source, pageIndex: 0, rotation: rotation, cropRect: nil, title: "Tuba")
        }

        let directory = folder.appendingPathComponent("ql")
        let upright = try await QuickLookFiles.prepare([item(0)], in: directory)
        let upsideDown = try await QuickLookFiles.prepare([item(180)], in: directory)
        #expect(upright != upsideDown)
        #expect(try PDFFixtures.topAndBottomInk(ofPage: 0, in: upright[0]).top > 0.3)
        #expect(try PDFFixtures.topAndBottomInk(ofPage: 0, in: upsideDown[0]).bottom > 0.3)
    }

    @Test("Asking again reuses the files rather than drawing them again")
    func filesAreReused() async throws {
        let folder = try PDFFixtures.directory()
        let source = folder.appendingPathComponent("Marsch.pdf")
        try PDFFixtures.scannedPDF(labels: ["Tuba"], at: source)
        let item = page(source)
        let directory = folder.appendingPathComponent("ql")

        let url = try await QuickLookFiles.prepare([item], in: directory)[0]
        let written = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        _ = try await QuickLookFiles.prepare([item], in: directory)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == written)
    }

    @Test("A source file that's gone is an error, not a blank preview")
    func missingSourceThrows() async throws {
        let folder = try PDFFixtures.directory()
        let gone = page(folder.appendingPathComponent("nope.pdf"))
        await #expect(throws: (any Error).self) {
            _ = try await QuickLookFiles.prepare([gone], in: folder.appendingPathComponent("ql"))
        }
    }
}
