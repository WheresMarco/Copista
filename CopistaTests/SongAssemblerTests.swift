import Testing
import Foundation
@testable import Copista

@Suite struct SongAssemblerTests {

    private func page(_ index: Int, kind: PartKind, extras: [UUID] = []) -> CachedPageResult {
        CachedPageResult(pageIndex: index, kind: kind, extraInstruments: extras, rotation: 0, cropRect: nil, detectedText: nil, confidence: 0.9, source: .textLayer)
    }

    @Test("Consecutive same-kind pages merge into one part")
    func continuationMerges() {
        let clarinet = UUID()
        let doc = SongAssembler.DocumentPages(documentID: UUID(), results: [
            page(0, kind: .instrument(clarinet)),
            page(1, kind: .instrument(clarinet)),
            page(2, kind: .instrument(clarinet)),
        ])
        let (parts, issues) = SongAssembler.assemble(songTitle: "Test", documents: [doc])
        #expect(parts.count == 1)
        #expect(parts[0].pages.count == 3)
        #expect(issues.isEmpty)
    }

    @Test("Score pages from multiple documents merge into a single score part at the front")
    func scoreMerges() {
        let clarinet = UUID()
        let scoreDoc = SongAssembler.DocumentPages(documentID: UUID(), results: [page(0, kind: .score), page(1, kind: .score)])
        let partDoc = SongAssembler.DocumentPages(documentID: UUID(), results: [page(0, kind: .instrument(clarinet))])
        let (parts, _) = SongAssembler.assemble(songTitle: "Test", documents: [partDoc, scoreDoc])

        #expect(parts.count == 2)
        if case .score = parts[0].kind {} else { Issue.record("expected score part first") }
        #expect(parts[0].pages.count == 2)
    }

    @Test("A second part claiming the same instrument becomes a flagged variant, not an overwrite")
    func duplicateInstrumentBecomesVariant() {
        let horn = UUID()
        let doc = SongAssembler.DocumentPages(documentID: UUID(), results: [
            page(0, kind: .instrument(horn)),
        ])
        let doc2 = SongAssembler.DocumentPages(documentID: UUID(), results: [
            page(0, kind: .instrument(horn)),
        ])
        let (parts, issues) = SongAssembler.assemble(songTitle: "Test", documents: [doc, doc2])

        #expect(parts.count == 2)
        #expect(parts[0].variantLabel == nil)
        #expect(parts[1].variantLabel != nil || parts[1].kind == parts[0].kind)
        #expect(issues.contains { if case .duplicateInstrument(let id) = $0 { return id == horn }; return false })
    }

    @Test("A combined part's extra instruments carry through to the assembled Part")
    func combinedExtrasCarryThrough() {
        let horn3 = UUID(), horn4 = UUID()
        let doc = SongAssembler.DocumentPages(documentID: UUID(), results: [
            page(0, kind: .instrument(horn3), extras: [horn4]),
        ])
        let (parts, _) = SongAssembler.assemble(songTitle: "Test", documents: [doc])
        #expect(parts[0].extraInstruments == [horn4])
    }
}

@Suite struct SongAssemblerBlankPageTests {
    private func page(_ index: Int, kind: PartKind, source: DetectionSource = .textLayer) -> CachedPageResult {
        CachedPageResult(pageIndex: index, kind: kind, extraInstruments: [], rotation: 0, cropRect: nil, detectedText: nil, confidence: 0.9, source: source)
    }

    @Test("A blank page in the middle of a part stays in it, as a page-turn gap")
    func interiorBlankStaysInPart() {
        let horn = UUID()
        let doc = SongAssembler.DocumentPages(documentID: UUID(), results: [
            page(0, kind: .instrument(horn)), page(1, kind: .blank), page(2, kind: .instrument(horn)),
        ])
        let (parts, issues) = SongAssembler.assemble(songTitle: "Test", documents: [doc])
        #expect(parts.count == 1)
        #expect(parts[0].pages.map(\.pageIndex) == [0, 1, 2])
        #expect(issues.isEmpty)
    }

    @Test("A blank page between two parts or at the end stays out of the print")
    func boundaryBlanksAreDropped() {
        let horn = UUID(), tuba = UUID()
        let doc = SongAssembler.DocumentPages(documentID: UUID(), results: [
            page(0, kind: .instrument(horn)), page(1, kind: .blank), page(2, kind: .instrument(tuba)), page(3, kind: .blank),
        ])
        let (parts, _) = SongAssembler.assemble(songTitle: "Test", documents: [doc])
        #expect(parts.first { $0.kind == .instrument(horn) }?.pages.count == 1)
        #expect(parts.first { $0.kind == .instrument(tuba) }?.pages.count == 1)
        #expect(parts.first { $0.kind == .blank }?.pages.map(\.pageIndex) == [1, 3])
    }

    @Test("A page excluded by hand stays excluded even mid-part")
    func manualExclusionStays() {
        let horn = UUID()
        let doc = SongAssembler.DocumentPages(documentID: UUID(), results: [
            page(0, kind: .instrument(horn)), page(1, kind: .blank, source: .manual), page(2, kind: .instrument(horn)),
        ])
        let (parts, _) = SongAssembler.assemble(songTitle: "Test", documents: [doc])
        #expect(parts.first { $0.kind == .instrument(horn) }?.pages.map(\.pageIndex) == [0, 2])
        #expect(parts.first { $0.kind == .blank }?.pages.map(\.pageIndex) == [1])
    }
}
