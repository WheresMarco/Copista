import Testing
import Foundation
import PDFKit
@testable import Copista

/// End-to-end coverage of rasterization and detection against generated PDFs. These exist because
/// every piece upstream of them can be individually correct while the assembled pipeline isn't.
@Suite struct DetectionPipelineTests {
    static let instruments = InstrumentCatalog.seedInstruments()
    static let matcher = NameMatcher(instruments: instruments)

    private func key(of result: CachedPageResult) -> String? {
        guard case .instrument(let id) = result.kind else { return nil }
        return Self.instruments.first { $0.id == id }?.key
    }

    @Test("Raster row 0 is the visual top of the page", arguments: [0, 90, 180, 270])
    func rasterIsUpright(rotation: Int) throws {
        let url = try PDFFixtures.directory().appendingPathComponent("band.pdf")
        try PDFFixtures.topBandPDF(at: url, rotation: rotation)

        let ink = try PDFFixtures.topAndBottomInk(ofPage: 0, in: url)
        #expect(ink.top > 0.9, "top of page should be black, got \(ink.top)")
        #expect(ink.bottom < 0.1, "bottom of page should be white, got \(ink.bottom)")
    }

    @Test("A raster keeps the page's visual proportions under /Rotate")
    func rasterProportions() throws {
        let url = try PDFFixtures.directory().appendingPathComponent("band.pdf")
        try PDFFixtures.topBandPDF(at: url, rotation: 90)
        let page = try #require(PDFDocument(url: url)?.page(at: 0))
        let raster = try #require(PageRasterizer.raster(page, longSide: 842))
        // A4 portrait with /Rotate 90 is displayed landscape.
        #expect(raster.width > raster.height)
    }

    @Test("A scanned PDF with no text layer is sorted into parts by OCR")
    func scannedPartsAreRecognized() async throws {
        let url = try PDFFixtures.directory().appendingPathComponent("Festmarsch.pdf")
        try PDFFixtures.scannedPDF(labels: ["Klarinett 1", "Klarinett 2", "Trombon 1", "Tuba", "Horn 1"], at: url)

        let analyzer = DocumentAnalyzer(matcher: Self.matcher)
        let results = try await analyzer.analyze(DocumentRef(id: UUID(), url: url, songTitle: "Festmarsch", pageCount: 5))

        #expect(results.map(key(of:)) == ["clarinet.bb.1", "clarinet.bb.2", "trombone.1", "tuba.1", "horn.1"])
        #expect(results.allSatisfy { $0.source == .ocr })
    }

    private func analyze(_ pages: [[(text: String, position: PDFFixtures.TopPosition)]], asScan: Bool, bodyText: String? = nil) async throws -> [CachedPageResult] {
        let url = try PDFFixtures.directory().appendingPathComponent("Festmarsch.pdf")
        try PDFFixtures.headedPDF(pages: pages, asScan: asScan, bodyText: bodyText, at: url)
        let analyzer = DocumentAnalyzer(matcher: Self.matcher)
        return try await analyzer.analyze(DocumentRef(id: UUID(), url: url, songTitle: "Festmarsch", pageCount: pages.count))
    }

    @Test("Pages stay with the part until a new name turns up top left or top right", arguments: [false, true])
    func partRunsUntilNewName(asScan: Bool) async throws {
        let results = try await analyze([
            [("Klarinett 1", .left)], [], [],
            [("Trombon 1", .right)], [],
            [("Tuba", .left)],
        ], asScan: asScan)

        #expect(results.map(key(of:)) == ["clarinet.bb.1", "clarinet.bb.1", "clarinet.bb.1", "trombone.1", "trombone.1", "tuba.1"])
        #expect(results.map { $0.source == .continuation } == [false, true, true, false, true, false])
    }

    @Test("A title with an instrument in it, between the corners, isn't a new part", arguments: [false, true])
    func titleDoesNotEndPart(asScan: Bool) async throws {
        let results = try await analyze([[("Horn 1", .left), ("Trumpet Voluntary", .middle)], [("Trumpet Voluntary", .middle)]], asScan: asScan)
        #expect(results.map(key(of:)) == ["horn.1", "horn.1"])
    }

    @Test("A name centred on a line of its own is a new part: some editions print them there", arguments: [false, true])
    func centredNameIsNewPart(asScan: Bool) async throws {
        let results = try await analyze([[("Horn 1", .middle)], [], [("Tuba 2", .middle)], []], asScan: asScan)
        #expect(results.map(key(of:)) == ["horn.1", "horn.1", "tuba.2", "tuba.2"])
    }

    @Test("A barely read name repeating the part these pages are in isn't a question")
    func repeatedGuessIsNotUncertain() async throws {
        let results = try await analyze([[("Piccolo", .left)], [("Piccolo (Ad lib.)", .middle)]], asScan: true)
        #expect(results.map(key(of:)) == ["piccolo.1", "piccolo.1"])
        #expect(results[1].confidence >= PageItem.uncertainBelow)
    }

    @Test("An instrument named further down the page doesn't end a part")
    func bodyTextDoesNotEndPart() async throws {
        let results = try await analyze([[("Horn 1", .left)], []], asScan: false, bodyText: "Solo tuba")
        #expect(results.map(key(of:)) == ["horn.1", "horn.1"])
    }

    @Test("Before any part has started, a name in the middle still counts", arguments: [false, true])
    func firstNameCanBeAnywhere(asScan: Bool) async throws {
        let results = try await analyze([[("Tuba", .middle)], []], asScan: asScan)
        #expect(results.map(key(of:)) == ["tuba.1", "tuba.1"])
    }

    @Test("Pages with no name before the first part have no instrument", arguments: [false, true])
    func noPartToContinue(asScan: Bool) async throws {
        let results = try await analyze([[], [], [("Tuba", .left)]], asScan: asScan)
        #expect(results.map(\.kind).prefix(2).allSatisfy { $0 == .unassigned })
        #expect(key(of: results[2]) == "tuba.1")
    }
}
