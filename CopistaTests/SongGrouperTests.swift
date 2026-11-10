import Testing
import Foundation
@testable import Copista

@Suite struct SongGrouperTests {

    static let grouper = SongGrouper(matcher: NameMatcher(instruments: InstrumentCatalog.seedInstruments()))

    private func urls(_ directory: String, _ filenames: [String]) -> [URL] {
        let dir = URL(fileURLWithPath: "/tmp/CopistaTestLibrary/\(directory)", isDirectory: true)
        return filenames.map { dir.appendingPathComponent($0) }
    }

    @Test("A folder of per-instrument files becomes one song; the duplicate set and the score are flagged")
    func olympicFolderIsOneSong() {
        let files = urls("Olympic", [
            "Olympic - Alto Sax 1.pdf", "Olympic - Alto Sax 2.pdf", "Olympic - Clarinet in Bb 1.pdf",
            "Olympic - Clarinet in Bb 2.pdf", "Olympic - Clarinet in Bb 3.pdf", "Olympic - Horn in F 1.pdf",
            "Olympic - Horn in F 2.pdf", "Olympic - Piccolo 1.pdf", "Olympic - Piccolo 2.pdf",
            "Olympic - Score.pdf", "Olympic - Tuba.pdf", "Olympic_Set.pdf",
        ])
        let songs = Self.grouper.group(urls: files)
        #expect(songs.count == 1)
        let song = songs[0]
        #expect(song.title == "Olympic")
        #expect(song.layout == .folderIsSong)

        let setDoc = song.documents.first { $0.url.lastPathComponent == "Olympic_Set.pdf" }
        #expect(setDoc?.role == .duplicateSet)
        let scoreDoc = song.documents.first { $0.url.lastPathComponent == "Olympic - Score.pdf" }
        #expect(scoreDoc?.role == .score)
    }

    @Test("The folder name wins over a repeated Swedish filename prefix that names a different title")
    func supermanFolderNameWinsOverFilePrefix() {
        let files = urls("Superman", [
            "Stålmannen Vh 1.pdf", "Stålmannen Vh 2.pdf", "Stålmannen Tp 1.pdf", "Stålmannen Tp 2.pdf",
            "Stålmannen klar 1.pdf", "Stålmannen klar2.pdf", "Stålmannen Trb 1.pdf", "Superman Tenorsax.pdf",
        ])
        let songs = Self.grouper.group(urls: files)
        #expect(songs.count == 1)
        #expect(songs[0].title == "Superman")
    }

    @Test("A repeated prefix that's longer than a wordy folder name trims the folder name down")
    func longFilePrefixTrimsWordyFolderName() {
        let dir = URL(fileURLWithPath: "/tmp/CopistaTestLibrary/8_PåMarsch_MRS-Marsch", isDirectory: true)
        let files = [
            "På Marsch Altsax1.pdf", "På Marsch Klar 1.pdf", "På Marsch Klar 2.pdf", "På Marsch Trumpet 1.pdf",
            "På Marsch Trumpet 2.pdf", "På Marsch Tuba 1.pdf", "På Marsch Valthorn 1.pdf",
        ].map { dir.appendingPathComponent($0) }

        let songs = Self.grouper.group(urls: files)
        #expect(songs.count == 1)
        #expect(songs[0].title == "På Marsch")
    }

    @Test("A composer name repeated in every filename does not override a clean folder name")
    func eagleSquadronKeepsFolderNameDespiteRepeatedComposer() {
        let files = urls("Eagle Squadron", [
            "Eagle Squadron ALFORD 00 particell.pdf", "Eagle Squadron ALFORD 01 fl.pdf",
            "Eagle Squadron ALFORD 02 ob.pdf", "Eagle Squadron ALFORD 11 hrn1-2.pdf",
            "Eagle Squadron ALFORD 12 hrn3-4.pdf", "Eagle Squadron ALFORD 19 tuba.pdf",
        ])
        let songs = Self.grouper.group(urls: files)
        #expect(songs.count == 1)
        #expect(songs[0].title == "Eagle Squadron")

        let particell = songs[0].documents.first { $0.url.lastPathComponent.contains("particell") }
        #expect(particell?.role == .score)
    }

    @Test("A folder with no instrument hits becomes one song per file")
    func unrelatedFilesEachBecomeTheirOwnSong() {
        let files = urls("Tyroler (2024)", (1...10).map { "Song\($0).pdf" })
        let songs = Self.grouper.group(urls: files)
        #expect(songs.count == 10)
        #expect(songs.allSatisfy { $0.layout == .fileIsSong })
    }

    @Test("Full Score and Parts files for the same title merge into one song, two documents")
    func fullScoreAndPartsMergeIntoOneSong() {
        let files = urls("Valborg", ["Valborg - Full Score.pdf", "Valborg - Parts.pdf"])
        let songs = Self.grouper.group(urls: files)
        #expect(songs.count == 1)
        #expect(songs[0].title == "Valborg")
        #expect(songs[0].documents.count == 2)
        #expect(songs[0].layout == .fileIsSong)

        let score = songs[0].documents.first { $0.url.lastPathComponent.contains("Full Score") }
        #expect(score?.role == .score)
    }

    @Test("A mixed score-and-parts document (Partitur och stämmor) is not pre-labeled pure score")
    func mixedScoreAndPartsDocumentStaysParts() {
        let files = urls("Macken-medley", ["Macken-medley - Partitur och stämmor.pdf"])
        let songs = Self.grouper.group(urls: files)
        #expect(songs.count == 1)
        #expect(songs[0].documents[0].role == .parts)
    }

    @Test("A _Set suffix alongside a plain sibling file is flagged as the duplicate")
    func setSuffixWithSiblingIsFlagged() {
        let files = urls("Svensk Flygarmarsch", ["Svensk_Flygarmarsch.pdf", "Svensk_Flygarmarsch_Set.pdf"])
        let songs = Self.grouper.group(urls: files)
        #expect(songs.count == 1)
        #expect(songs[0].title == "Svensk Flygarmarsch")
        let setDoc = songs[0].documents.first { $0.url.lastPathComponent.contains("_Set") }
        #expect(setDoc?.role == .duplicateSet)
    }
}
