import Testing
import Foundation
import PDFKit
@testable import Copista

/// Exercises the detection pipeline against the user's real sheet-music library, to verify the
/// plan's test table (§10) against actual files rather than synthetic fixtures. Skips cleanly
/// if the library isn't present (e.g. CI, another machine) — this is a verification aid, not a
/// portable regression test, so it is not part of the permanent suite.
@Suite struct RealLibraryVerificationTests {

    // The sandboxed test host can't see ~/Dropbox directly; a subset of the real library was
    // copied into the app's own sandbox container (tmp/CopistaTestLibrary) for this run.
    static let libraryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("CopistaTestLibrary")

    static var isLibraryAvailable: Bool {
        FileManager.default.fileExists(atPath: libraryRoot.path)
    }

    static let instruments = InstrumentCatalog.seedInstruments()
    static let matcher = NameMatcher(instruments: instruments)

    private func pdfs(in relativePath: String) throws -> [URL] {
        let dir = Self.libraryRoot.appendingPathComponent(relativePath)
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        return contents.filter { $0.pathExtension.lowercased() == "pdf" }
    }

    @Test("Olympic: folder is one song, Set is flagged, Score is flagged", .enabled(if: isLibraryAvailable))
    func olympic() throws {
        let songs = SongGrouper(matcher: Self.matcher).group(urls: try pdfs(in: "Lilla Konsert Mappen/Olympic"))
        #expect(songs.count == 1)
        #expect(songs.first?.title == "Olympic")
        let setDoc = songs.first?.documents.first { $0.url.lastPathComponent == "Olympic_Set.pdf" }
        #expect(setDoc?.role == .duplicateSet)
        let scoreDoc = songs.first?.documents.first { $0.url.lastPathComponent == "Olympic - Score.pdf" }
        #expect(scoreDoc?.role == .score)
    }

    @Test("Olympic: its files picked out and added together are one song, named Olympic", .enabled(if: isLibraryAvailable))
    func olympicFilesAddedTogether() throws {
        let song = SongGrouper(matcher: Self.matcher).groupAsOneSong(urls: try pdfs(in: "Lilla Konsert Mappen/Olympic"))
        #expect(song.title == "Olympic")
        #expect(song.documents.first { $0.url.lastPathComponent == "Olympic_Set.pdf" }?.role == .duplicateSet)
        #expect(song.documents.first { $0.url.lastPathComponent == "Olympic - Score.pdf" }?.role == .score)
    }

    @Test("Superman: title is 'Superman', not the Swedish file prefix", .enabled(if: isLibraryAvailable))
    func superman() throws {
        let songs = SongGrouper(matcher: Self.matcher).group(urls: try pdfs(in: "Stora mappen/Superman"))
        #expect(songs.count == 1)
        #expect(songs.first?.title == "Superman")
    }

    @Test("Eagle Squadron: title keeps the folder name despite the repeated composer", .enabled(if: isLibraryAvailable))
    func eagleSquadron() throws {
        let songs = SongGrouper(matcher: Self.matcher).group(urls: try pdfs(in: "Stora mappen/Eagle Squadron"))
        #expect(songs.count == 1)
        #expect(songs.first?.title == "Eagle Squadron")
    }

    @Test("Valborg: Full Score and Parts merge into one song, two documents", .enabled(if: isLibraryAvailable))
    func valborg() throws {
        let songs = SongGrouper(matcher: Self.matcher).group(urls: try pdfs(in: "Lilla Konsert Mappen/Valborg"))
        #expect(songs.count == 1)
        #expect(songs.first?.documents.count == 2)
    }

    @Test("Tyroler (2024): 24 unrelated files become 24 separate songs", .enabled(if: isLibraryAvailable))
    func tyroler() throws {
        let songs = SongGrouper(matcher: Self.matcher).group(urls: try pdfs(in: "Tyroler (2024)"))
        #expect(songs.count == 24)
        #expect(songs.allSatisfy { $0.layout == .fileIsSong })
    }

    @Test("Olympic - Clarinet in Bb 1: a 1-page filename-matched document resolves via the filename path", .enabled(if: isLibraryAvailable))
    func olympicClarinetFilenameMatch() async throws {
        let url = Self.libraryRoot.appendingPathComponent("Lilla Konsert Mappen/Olympic/Olympic - Clarinet in Bb 1.pdf")
        let analyzer = DocumentAnalyzer(matcher: Self.matcher)
        let ref = DocumentRef(id: UUID(), url: url, songTitle: "Olympic", pageCount: 1)
        let results = try await analyzer.analyze(ref)
        #expect(results.count == 1)
        if case .instrument(let id) = results[0].kind {
            let instrument = Self.instruments.first { $0.id == id }
            #expect(instrument?.key == "clarinet.bb.1")
        } else {
            Issue.record("expected an instrument match, got \(results[0].kind)")
        }
        #expect(results[0].source == .filename)
    }

    @Test("Macken-medley: pages 1–12 are score, later pages are individual parts (text layer)", .enabled(if: isLibraryAvailable))
    func mackenMedleyScoreThenParts() async throws {
        let url = Self.libraryRoot.appendingPathComponent("Stora mappen/Macken-medley/Macken-medley - Partitur och stämmor.pdf")
        let analyzer = DocumentAnalyzer(matcher: Self.matcher)
        let ref = DocumentRef(id: UUID(), url: url, songTitle: "Macken-medley", pageCount: 42)
        let results = try await analyzer.analyze(ref)
        #expect(results.count == 42)

        let scorePages = results.filter { if case .score = $0.kind { return true }; return false }
        #expect(scorePages.count >= 10, "expected roughly the first dozen pages to be detected as score, got \(scorePages.count)")

        let instrumentPages = results.filter { if case .instrument = $0.kind { return true }; return false }
        #expect(!instrumentPages.isEmpty, "expected at least some pages to resolve to an instrument via the text layer")
        #expect(results.allSatisfy { $0.source != .continuation || $0.kind == .score }, "every part in this file has a printed name")
    }

    @Test("Valborg - Parts: all 27 pages resolve to an instrument by OCR", .enabled(if: isLibraryAvailable))
    func valborgPartsResolves() async throws {
        let url = Self.libraryRoot.appendingPathComponent("Lilla Konsert Mappen/Valborg/Valborg - Parts.pdf")
        let analyzer = DocumentAnalyzer(matcher: Self.matcher)
        let ref = DocumentRef(id: UUID(), url: url, songTitle: "Valborg", pageCount: 27)
        let results = try await analyzer.analyze(ref)
        #expect(results.count == 27)
        #expect(results.allSatisfy { if case .instrument = $0.kind { return true }; return false })
        #expect(results.allSatisfy { $0.rotation == 0 }, "landscape pages must not be turned sideways")
    }
}
