import Testing
import Foundation
@testable import Copista

@Suite struct PageSelectionTests {
    private let order = (0..<6).map { _ in UUID() }

    @Test("A plain click selects just that page")
    func plainClick() {
        var selection = PageSelection()
        selection.click(order[1], modifier: .none, in: order)
        selection.click(order[3], modifier: .none, in: order)
        #expect(selection.ids == [order[3]])
        #expect(selection.focus == order[3])
    }

    @Test("⌘-click adds and removes single pages")
    func commandClick() {
        var selection = PageSelection()
        selection.click(order[1], modifier: .none, in: order)
        selection.click(order[3], modifier: .toggle, in: order)
        #expect(selection.ids == [order[1], order[3]])
        selection.click(order[1], modifier: .toggle, in: order)
        #expect(selection.ids == [order[3]])
    }

    @Test("⇧-click takes in the range from the last click, either direction")
    func shiftClick() {
        var selection = PageSelection()
        selection.click(order[2], modifier: .none, in: order)
        selection.click(order[4], modifier: .extend, in: order)
        #expect(selection.orderedIDs(in: order) == Array(order[2...4]))
        selection.click(order[0], modifier: .extend, in: order)
        #expect(selection.orderedIDs(in: order) == Array(order[0...2]), "the range measures from the same start")
    }

    @Test("⇧-click with nothing selected selects just that page")
    func shiftClickFromNothing() {
        var selection = PageSelection()
        selection.click(order[3], modifier: .extend, in: order)
        #expect(selection.ids == [order[3]])
    }

    @Test("Arrow keys step and stop at the ends; ⇧ extends")
    func arrowKeys() {
        var selection = PageSelection()
        selection.move(by: 1, extending: false, in: order)
        #expect(selection.ids == [order[0]], "starts on the first page")
        selection.move(by: -1, extending: false, in: order)
        #expect(selection.ids == [order[0]], "stops at the start")
        selection.move(by: 1, extending: true, in: order)
        selection.move(by: 1, extending: true, in: order)
        #expect(selection.orderedIDs(in: order) == Array(order[0...2]))
    }

    @Test("Selected pages come back in display order, whatever order they were clicked")
    func orderedIDs() {
        var selection = PageSelection()
        selection.click(order[4], modifier: .none, in: order)
        selection.click(order[1], modifier: .toggle, in: order)
        #expect(selection.orderedIDs(in: order) == [order[1], order[4]])
    }
}

@Suite struct ReviewItemTests {
    private func page(_ index: Int = 0, confidence: Double = 0.9, source: DetectionSource = .ocr) -> PageItem {
        PageItem(id: UUID(), documentID: UUID(), pageIndex: index, rotation: 0, cropRect: nil, detectedText: nil, confidence: confidence, source: source)
    }

    private func song(_ parts: [Part]) -> Song {
        Song(id: UUID(), title: "Test", documentIDs: [], parts: parts, issues: [], includeScore: false)
    }

    private func part(_ kind: PartKind, _ pages: [PageItem], variant: String? = nil) -> Part {
        Part(id: UUID(), songTitle: "Test", kind: kind, pages: pages, variantLabel: variant)
    }

    @Test("Pages without an instrument are what must be fixed, and come first")
    func mustFixFirst() {
        let horn = UUID()
        let unknown = page(confidence: 0, source: .continuation)
        let items = song([part(.instrument(horn), [page(confidence: 0.55)]), part(.unassigned, [unknown])]).reviewItems
        #expect(items.first?.kind == .noInstrument)
        #expect(items.first?.pageIDs == [unknown.id])
        #expect(items.first?.severity == .mustFix)
    }

    @Test("A well-read song has nothing to report")
    func cleanSong() {
        #expect(song([part(.instrument(UUID()), [page()]), part(.score, [page(confidence: 0.5, source: .continuation)])]).reviewItems.isEmpty)
    }

    @Test("A name barely read is to check; unfamiliar words where a name goes are only a note")
    func severities() {
        let horn = UUID()
        var unfamiliar = page(confidence: 0.5, source: .continuation)
        unfamiliar.detectedText = "Xylofon"
        let items = song([part(.instrument(horn), [page(confidence: 0.55), unfamiliar])]).reviewItems
        #expect(items.map(\.kind) == [.hardToRead, .unknownLabel])
        #expect(items.map(\.severity) == [.check, .note])
    }

    @Test("A page with nothing where a name goes is just the part's next page")
    func plainContinuationIsNotAnIssue() {
        let horn = UUID()
        #expect(song([part(.instrument(horn), [page(), page(1, confidence: 0.5, source: .continuation)])]).reviewItems.isEmpty)
    }

    @Test("A second part for an instrument asks about the later part only, until it's kept")
    func duplicates() {
        let horn = UUID()
        let first = part(.instrument(horn), [page()])
        let later = page()
        let open = song([first, part(.instrument(horn), [later], variant: "Horn")])
        #expect(open.reviewItems == [ReviewItem(kind: .duplicatePart(instrumentID: horn), pageIDs: [later.id])])

        var kept = later
        kept.source = .manual
        #expect(song([first, part(.instrument(horn), [kept], variant: "Horn")]).reviewItems.isEmpty)
    }

    @Test("The sidebar counts pages that must be fixed apart from those to check")
    func counts() {
        let horn = UUID()
        let s = song([
            part(.unassigned, [page(confidence: 0, source: .continuation), page(confidence: 0, source: .continuation)]),
            part(.instrument(horn), [page(confidence: 0.55)]),
            part(.instrument(horn), [page(), page()]),
        ])
        #expect(s.mustFixCount == 2)
        #expect(s.checkCount == 2, "one uncertain page and one duplicate part, however long it is")
    }
}

@Suite struct InstrumentOrderingTests {
    static let instruments = InstrumentCatalog.seedInstruments()

    private func id(_ key: String) -> UUID {
        Self.instruments.first { $0.key == key }!.id
    }

    private func part(_ kind: PartKind) -> Part {
        Part(id: UUID(), songTitle: "Test", kind: kind, pages: [])
    }

    @Test("Instruments group by section, each in score order")
    func grouped() {
        let groups = InstrumentCatalog.grouped(Self.instruments.reversed())
        #expect(groups.map(\.section) == [.woodwinds, .brass, .strings, .percussion, .rhythm], "no empty Other section")
        #expect(groups.flatMap(\.instruments).count == Self.instruments.count)
        for group in groups {
            #expect(group.instruments.map(\.sortIndex) == group.instruments.map(\.sortIndex).sorted())
        }
    }

    @Test("A custom instrument goes under Other")
    func customInstrument() {
        let custom = Instrument(id: UUID(), key: nil, customName: "Säckpipa", sortIndex: 99, defaultCopies: 1, includedByDefault: true, aliases: [])
        #expect(InstrumentCatalog.grouped(Self.instruments + [custom]).last?.section == .other)
    }

    @Test("Parts show unknown first, then score, then score order, then what won't print")
    func partOrder() {
        let tuba = part(.instrument(id("tuba.1")))
        let clarinet = part(.instrument(id("clarinet.bb.2")))
        let flute = part(.instrument(id("flute.1")))
        let snare = part(.instrument(id("snare")))
        let blank = part(.blank), score = part(.score), unknown = part(.unassigned)
        let song = Song(id: UUID(), title: "Test", documentIDs: [], parts: [blank, tuba, snare, clarinet, score, flute, unknown], issues: [], includeScore: false)

        let groups = song.partGroups(instruments: Self.instruments)
        #expect(groups.map(\.kind) == [.unassigned, .score, .section(.woodwinds), .section(.brass), .section(.percussion), .blank])
        #expect(groups.flatMap(\.parts).map(\.id) == [unknown, score, flute, clarinet, tuba, snare, blank].map(\.id))
    }

    @Test("Two parts for one instrument stay in the order they came, and no part is ever lost")
    func variantsStayInOrder() {
        let gone = part(.instrument(UUID()))
        let first = part(.instrument(id("horn.1"))), second = part(.instrument(id("horn.1")))
        let song = Song(id: UUID(), title: "Test", documentIDs: [], parts: [second, gone, first], issues: [], includeScore: false)

        let shown = song.partGroups(instruments: Self.instruments).flatMap(\.parts).map(\.id)
        #expect(shown == [second.id, first.id, gone.id], "an instrument since removed lands under Other")
    }
}

@Suite @MainActor struct MultiPageEditTests {
    private func imported(labels: [String]) async throws -> (AppModel, URL) {
        let support = try PDFFixtures.directory("support")
        let url = try PDFFixtures.directory().appendingPathComponent("Marsch.pdf")
        try PDFFixtures.scannedPDF(labels: labels, at: url)
        let model = AppModel(settings: SettingsStore(directory: support), corrections: CorrectionStore(directory: support))
        model.importURLs([url])
        await model.waitForImports()
        return (model, support)
    }

    private func id(_ model: AppModel, _ key: String) -> UUID {
        model.settings.instruments.first { $0.key == key }!.id
    }

    private func pages(_ model: AppModel, in kind: PartKind) -> [Int] {
        model.songs[0].parts.first { $0.kind == kind }?.pages.map(\.pageIndex) ?? []
    }

    @Test("Giving a page an instrument brings the pages after it, up to the next page with a name")
    func assignmentCarriesForward() async throws {
        // A first page whose name can't be read, and the rest of that part after it.
        let (model, _) = try await imported(labels: ["Bombardon", "", "", "Tuba", ""])
        let song = try #require(model.songs.first)
        #expect(pages(model, in: .unassigned) == [0, 1, 2])
        let first = try #require(song.parts.first { $0.kind == .unassigned }?.pages.first)

        let horn = id(model, "horn.1")
        model.setInstrument(horn, forPageIDs: [first.id], inSongID: song.id)

        #expect(pages(model, in: .instrument(horn)) == [0, 1, 2])
        #expect(pages(model, in: .instrument(id(model, "tuba.1"))) == [3, 4], "a page with its own name stays what it is")
        let moved = try #require(model.songs[0].parts.first { $0.kind == .instrument(horn) }?.pages)
        #expect(moved.map(\.source) == [.manual, .continuation, .continuation], "only the page that was picked counts as looked at")
    }

    @Test("A correction in the middle of a part takes the rest of that part's nameless pages along")
    func correctionMidPartCarriesForward() async throws {
        let (model, _) = try await imported(labels: ["Tuba", "", "", ""])
        let song = try #require(model.songs.first)
        let tuba = id(model, "tuba.1"), horn = id(model, "horn.1")
        let start = try #require(song.parts.first { $0.kind == .instrument(tuba) }?.pages[2])

        model.setInstrument(horn, forPageIDs: [start.id], inSongID: song.id)

        #expect(pages(model, in: .instrument(tuba)) == [0, 1])
        #expect(pages(model, in: .instrument(horn)) == [2, 3])
    }

    @Test("A page corrected by hand ends the run, and an excluded one is stepped over and stays out")
    func carryingStopsAtCorrections() async throws {
        let (model, _) = try await imported(labels: ["Tuba", "", "", "", ""])
        let song = try #require(model.songs.first)
        let tuba = id(model, "tuba.1"), horn = id(model, "horn.1"), oboe = id(model, "oboe.1")
        let all = try #require(song.parts.first { $0.kind == .instrument(tuba) }?.pages)
        model.excludePages([all[2].id], inSongID: song.id)
        model.setInstrument(oboe, forPageIDs: [all[4].id], inSongID: song.id)

        model.setInstrument(horn, forPageIDs: [all[1].id], inSongID: song.id)

        #expect(pages(model, in: .instrument(tuba)) == [0])
        #expect(pages(model, in: .instrument(horn)) == [1, 3])
        #expect(pages(model, in: .blank) == [2])
        #expect(pages(model, in: .instrument(oboe)) == [4])
    }

    @Test("A carried page stays where it was put when the file is added again")
    func carriedPagesSurviveReimport() async throws {
        let (model, support) = try await imported(labels: ["Bombardon", "", "Tuba"])
        let url = try #require(model.sourceDocuments.values.first?.url)
        let song = try #require(model.songs.first)
        let horn = id(model, "horn.1")
        let first = try #require(song.parts.first { $0.kind == .unassigned }?.pages.first)
        model.setInstrument(horn, forPageIDs: [first.id], inSongID: song.id)

        let again = AppModel(settings: SettingsStore(directory: support), corrections: CorrectionStore(directory: support))
        again.importURLs([url])
        await again.waitForImports()
        #expect(pages(again, in: .instrument(horn)) == [0, 1])
    }

    @Test("Several unknown pages get one instrument at once, in order, and it clears the issue")
    func assignSeveral() async throws {
        let (model, _) = try await imported(labels: ["Bombardon", "", "Tuba", "Bombardon"])
        let song = try #require(model.songs.first)
        let unknown = song.parts.filter { $0.kind == .unassigned }.flatMap(\.pages)
        #expect(!unknown.isEmpty)
        #expect(song.mustFixCount == unknown.count)

        let horn = id(model, "horn.1")
        model.setInstrument(horn, forPageIDs: unknown.map(\.id), inSongID: song.id)

        let updated = model.songs[0]
        #expect(updated.mustFixCount == 0)
        let hornPages = updated.parts.first { $0.kind == .instrument(horn) }?.pages.map(\.pageIndex) ?? []
        #expect(hornPages == unknown.map(\.pageIndex).sorted())
    }

    @Test("Excluding several pages keeps them out of the print")
    func excludeSeveral() async throws {
        let (model, _) = try await imported(labels: ["Horn 1", "Horn 2", "Trombon 1"])
        let song = try #require(model.songs.first)
        let targets = song.parts.flatMap(\.pages).prefix(2).map(\.id)
        model.excludePages(Array(targets), inSongID: song.id)
        #expect(model.outputPlans[0].plan.musicPageCount == 1)
    }

    @Test("Rotating several pages turns each of them")
    func rotateSeveral() async throws {
        let (model, _) = try await imported(labels: ["Horn 1", "Horn 2"])
        let song = try #require(model.songs.first)
        model.rotatePages(song.parts.flatMap(\.pages).map(\.id), inSongID: song.id)
        #expect(model.songs[0].parts.flatMap(\.pages).allSatisfy { $0.rotation == 90 })
    }

    @Test("Confirming a guess keeps the instrument, clears the flag, and is remembered")
    func confirmIsRemembered() async throws {
        let (model, support) = try await imported(labels: ["SPA CLARINET"])
        let song = try #require(model.songs.first)
        #expect(song.checkCount == 1)
        let before = song.parts[0].kind

        model.confirmPages(song.parts.flatMap(\.pages).map(\.id), inSongID: song.id)
        #expect(model.songs[0].reviewItems.isEmpty)
        #expect(model.songs[0].parts[0].kind == before)

        let url = try #require(model.sourceDocuments.values.first?.url)
        let relaunched = AppModel(settings: SettingsStore(directory: support), corrections: CorrectionStore(directory: support))
        relaunched.importURLs([url])
        await relaunched.waitForImports()
        #expect(relaunched.songs.first?.reviewItems.isEmpty == true)
    }

    @Test("Keeping a second part clears the question but both still print")
    func keepDuplicate() async throws {
        let (model, _) = try await imported(labels: ["Horn 1", "Tuba", "Horn 1"])
        let song = try #require(model.songs.first)
        let item = try #require(song.reviewItems.first { if case .duplicatePart = $0.kind { return true }; return false })

        model.confirmPages(item.pageIDs, inSongID: song.id)
        #expect(model.songs[0].reviewItems.allSatisfy { if case .duplicatePart = $0.kind { return false }; return true })
        #expect(model.songs[0].needsDuplicateIssueCleared)
        #expect(model.outputPlans[0].plan.musicPageCount == 3)
    }
}

private extension Song {
    var needsDuplicateIssueCleared: Bool {
        !issues.contains { if case .duplicateInstrument = $0 { return true }; return false }
    }
}

@Suite struct PageReorderingTests {
    private func pages(_ count: Int) -> [PageItem] {
        (0..<count).map { PageItem(id: UUID(), documentID: UUID(), pageIndex: $0, rotation: 0, cropRect: nil, detectedText: nil, confidence: 1, source: .ocr) }
    }

    private func order(_ pages: [PageItem]) -> [Int] {
        pages.map(\.pageIndex)
    }

    @Test("A page moves to just before or after another, either direction")
    func movesBothWays() {
        let p = pages(4)
        #expect(order(p.moving([p[3].id], relativeTo: p[1].id, after: false)) == [0, 3, 1, 2])
        #expect(order(p.moving([p[0].id], relativeTo: p[2].id, after: true)) == [1, 2, 0, 3])
    }

    @Test("A page can go first and last")
    func firstAndLast() {
        let p = pages(3)
        #expect(order(p.moving([p[2].id], relativeTo: p[0].id, after: false)) == [2, 0, 1])
        #expect(order(p.moving([p[0].id], relativeTo: p[2].id, after: true)) == [1, 2, 0])
    }

    @Test("Several pages move together, keeping their order")
    func movesTogether() {
        let p = pages(5)
        #expect(order(p.moving([p[1].id, p[3].id], relativeTo: p[4].id, after: true)) == [0, 2, 4, 1, 3])
    }

    @Test("Dropping a page on itself or one of its own group changes nothing")
    func noOp() {
        let p = pages(3)
        #expect(order(p.moving([p[1].id], relativeTo: p[1].id, after: true)) == [0, 1, 2])
        #expect(order(p.moving([p[0].id, p[1].id], relativeTo: p[1].id, after: false)) == [0, 1, 2])
    }

    @Test("A target outside the part changes nothing")
    func foreignTarget() {
        let p = pages(3)
        #expect(order(p.moving([p[0].id], relativeTo: UUID(), after: false)) == [0, 1, 2])
    }

    @Test("Stepping moves one place and stops at the ends")
    func stepping() {
        let p = pages(3)
        #expect(order(p.shifting([p[1].id], later: true)) == [0, 2, 1])
        #expect(order(p.shifting([p[1].id], later: false)) == [1, 0, 2])
        #expect(order(p.shifting([p[2].id], later: true)) == [0, 1, 2])
        #expect(order(p.shifting([p[0].id], later: false)) == [0, 1, 2])
    }
}

@Suite @MainActor struct PageOrderInAppTests {
    /// One three-page part: a name on the first page, none on the others.
    private func threePagePart(support: URL) async throws -> (AppModel, URL) {
        let url = try PDFFixtures.directory().appendingPathComponent("Marsch.pdf")
        try PDFFixtures.scannedPDF(labels: ["Horn 1", "", ""], at: url)
        let model = AppModel(settings: SettingsStore(directory: support), corrections: CorrectionStore(directory: support))
        model.importURLs([url])
        await model.waitForImports()
        return (model, url)
    }

    private func hornPages(_ model: AppModel) -> [Int] {
        let horn = model.settings.instruments.first { $0.key == "horn.1" }!.id
        return model.songs[0].parts.first { $0.kind == .instrument(horn) }?.pages.map(\.pageIndex) ?? []
    }

    @Test("A new page order is what prints")
    func orderPrints() async throws {
        let (model, _) = try await threePagePart(support: try PDFFixtures.directory("support"))
        let pages = model.songs[0].parts[0].pages
        model.reorderPages([pages[2].id], relativeTo: pages[0].id, after: false, inSongID: model.songs[0].id)

        #expect(hornPages(model) == [2, 0, 1])
        #expect(model.outputPlans[0].plan.sheets.map(\.pageIndex) == [2, 0, 1])
    }

    @Test("A page order survives a relaunch, and doesn't clear what's still to be checked")
    func orderIsRemembered() async throws {
        let support = try PDFFixtures.directory("support")
        let (model, url) = try await threePagePart(support: support)
        let pages = model.songs[0].parts[0].pages
        let flaggedBefore = model.songs[0].reviewItems.map(\.kind)
        model.shiftPages([pages[0].id], later: true, inSongID: model.songs[0].id)
        #expect(hornPages(model) == [1, 0, 2])
        #expect(model.songs[0].reviewItems.map(\.kind) == flaggedBefore)

        let relaunched = AppModel(settings: SettingsStore(directory: support), corrections: CorrectionStore(directory: support))
        relaunched.importURLs([url])
        await relaunched.waitForImports()
        #expect(hornPages(relaunched) == [1, 0, 2])
    }

    @Test("Dropping on another part's page leaves both parts alone")
    func otherPartIsIgnored() async throws {
        let support = try PDFFixtures.directory("support")
        let url = try PDFFixtures.directory().appendingPathComponent("Marsch.pdf")
        try PDFFixtures.scannedPDF(labels: ["Horn 1", "", "Horn 2", ""], at: url)
        let model = AppModel(settings: SettingsStore(directory: support), corrections: CorrectionStore(directory: support))
        model.importURLs([url])
        await model.waitForImports()

        let before = model.songs[0].parts.map { $0.pages.map(\.pageIndex) }
        let first = model.songs[0].parts[0].pages[0], otherPart = model.songs[0].parts[1].pages[0]
        model.reorderPages([first.id], relativeTo: otherPart.id, after: false, inSongID: model.songs[0].id)
        #expect(model.songs[0].parts.map { $0.pages.map(\.pageIndex) } == before)
    }

    @Test("Assigning a page to a reordered part keeps that part's order")
    func assignKeepsOrder() async throws {
        let (model, _) = try await threePagePart(support: try PDFFixtures.directory("support"))
        let song = model.songs[0]
        let pages = song.parts[0].pages
        model.excludePages([pages[1].id], inSongID: song.id)
        let horn = model.settings.instruments.first { $0.key == "horn.1" }!.id
        // Now [0, 2]: turn it around, then bring page 1 back.
        model.shiftPages([pages[2].id], later: false, inSongID: song.id)
        #expect(hornPages(model) == [2, 0])
        model.setInstrument(horn, forPageIDs: [pages[1].id], inSongID: song.id)
        #expect(hornPages(model).filter { $0 != 1 } == [2, 0], "the order chosen is still there")
        #expect(hornPages(model).contains(1))
    }
}

@Suite @MainActor struct FilesAddedTogetherTests {
    private func model() throws -> AppModel {
        let support = try PDFFixtures.directory("support")
        return AppModel(settings: SettingsStore(directory: support), corrections: CorrectionStore(directory: support))
    }

    private func files(_ names: [String], in folder: URL) throws -> [URL] {
        try names.map { name in
            let url = folder.appendingPathComponent(name + ".pdf")
            try PDFFixtures.scannedPDF(labels: ["Tuba"], at: url)
            return url
        }
    }

    private func imported(_ urls: [URL]) async throws -> AppModel {
        let m = try model()
        m.importURLs(urls)
        await m.waitForImports()
        return m
    }

    @Test("Several files added together are one song, named for what they share")
    func oneSong() async throws {
        let folder = try PDFFixtures.directory("Nerladdat")
        let m = try await imported(try files(["Olympic - Horn 1", "Olympic - Horn 2", "Olympic - Tuba"], in: folder))
        #expect(m.songs.map(\.title) == ["Olympic"])
        #expect(m.songs[0].documentIDs.count == 3)
    }

    @Test("Files with nothing obvious in common are still one song, named for their folder")
    func unrelatedNames() async throws {
        let folder = try PDFFixtures.directory("Vårkonsert")
        let m = try await imported(try files(["Festmarsch", "Valsen"], in: folder))
        #expect(m.songs.map(\.title) == ["Vårkonsert"])
    }

    @Test("A shared instrument name isn't taken for the song's name")
    func instrumentPrefixIsNotTheTitle() async throws {
        let folder = try PDFFixtures.directory("Marsch")
        let m = try await imported(try files(["Klarinett 1", "Klarinett 2", "Klarinett 3"], in: folder))
        #expect(m.songs.map(\.title) == ["Marsch"])
    }

    @Test("A title stops at the dash, even when most files share a word beyond it")
    func titleStopsAtDash() async throws {
        let folder = try PDFFixtures.directory("Nerladdat")
        let m = try await imported(try files(["Olympic - Klarinett 1", "Olympic - Klarinett 2", "Olympic - Tuba"], in: folder))
        #expect(m.songs.map(\.title) == ["Olympic"])
    }

    @Test("Underscored names share a title too")
    func underscores() async throws {
        let folder = try PDFFixtures.directory("Nerladdat")
        let m = try await imported(try files(["Olympic_Horn", "Olympic_Tuba"], in: folder))
        #expect(m.songs.map(\.title) == ["Olympic"])
    }

    @Test("One file added alone is still its own song")
    func singleFile() async throws {
        let folder = try PDFFixtures.directory("Nerladdat")
        let m = try await imported(try files(["Festmarsch"], in: folder))
        #expect(m.songs.map(\.title) == ["Festmarsch"])
    }

    @Test("A folder is still sorted by what's in it, even with unrelated songs inside")
    func folderKeepsItsRules() async throws {
        let folder = try PDFFixtures.directory("Tyroler")
        _ = try files(["Festmarsch", "Valsen", "Polka"], in: folder)
        let m = try await imported([folder])
        #expect(m.songs.count == 3)
    }

    @Test("Files and a folder added at once: the files are one song, the folder is sorted out")
    func filesAndFolder() async throws {
        let loose = try PDFFixtures.directory("Nerladdat")
        let looseFiles = try files(["Olympic - Horn 1", "Olympic - Tuba"], in: loose)
        let folder = try PDFFixtures.directory("Tyroler")
        _ = try files(["Festmarsch", "Valsen"], in: folder)
        let m = try await imported(looseFiles + [folder])
        #expect(Set(m.songs.map(\.title)) == ["Olympic", "Festmarsch", "Valsen"])
    }

    @Test("A complete set among files added together defers to the separate parts")
    func setIsSkipped() async throws {
        let folder = try PDFFixtures.directory("Nerladdat")
        let m = try await imported(try files(["Olympic_Set", "Olympic - Tuba", "Olympic - Horn 1"], in: folder))
        #expect(m.songs.count == 1)
        #expect(m.songs[0].documentIDs.count == 2)
    }

    @Test("A song can be renamed; blank names are ignored")
    func rename() async throws {
        let folder = try PDFFixtures.directory("Nerladdat")
        let m = try await imported(try files(["Festmarsch"], in: folder))
        m.renameSong(m.songs[0].id, to: "  Vårmarsch ")
        #expect(m.songs[0].title == "Vårmarsch")
        m.renameSong(m.songs[0].id, to: "   ")
        #expect(m.songs[0].title == "Vårmarsch")
    }
}
