import Foundation
import PDFKit
import CoreGraphics

nonisolated enum AnalyzerError: LocalizedError, Sendable {
    case unreadable
    case encrypted

    var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "The file couldn't be read as a PDF.")
        case .encrypted: String(localized: "The PDF is password protected.")
        }
    }
}

/// Classifies every page of one PDF into a part, the score, blank, or unassigned.
///
/// An `actor` because it owns the `PDFDocument`/`PDFPage` it opens — neither type is `Sendable`,
/// so they must never cross an isolation boundary. Everything that *does* cross a boundary here
/// (`DocumentRef`, `PageRaster`, `CachedPageResult`, `DetectionProgress`) is a plain Sendable
/// value. OCR work is delegated to `OCRService`, itself an actor, whose `perform(on:)` call is
/// where this analysis genuinely suspends off whatever actor invoked `analyze`.
actor DocumentAnalyzer {
    private let matcher: NameMatcher
    private let ocr: OCRService
    private let intelligentMatcher: IntelligentNameMatcher?

    init(matcher: NameMatcher, ocr: OCRService = OCRService(), intelligentMatcher: IntelligentNameMatcher? = nil) {
        self.matcher = matcher
        self.ocr = ocr
        self.intelligentMatcher = intelligentMatcher
    }

    func analyze(_ ref: DocumentRef, progress: AsyncStream<DetectionProgress>.Continuation? = nil) async throws -> [CachedPageResult] {
        progress?.yield(.started(documentID: ref.id, title: ref.songTitle, pageCount: ref.pageCount))
        defer { progress?.yield(.finished(documentID: ref.id)) }

        guard let document = PDFDocument(url: ref.url) else { throw AnalyzerError.unreadable }
        if document.isEncrypted, document.isLocked { throw AnalyzerError.encrypted }

        if let bookmarkResults = analyzeBookmarks(document) { return bookmarkResults }
        if document.pageCount <= 4, let filenameResults = analyzeFilename(ref, pageCount: document.pageCount) {
            return filenameResults
        }

        var results: [CachedPageResult] = []
        var previousInstrumentKind: PartKind?

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            progress?.yield(.page(documentID: ref.id, index: index))

            var result = try await analyzePage(page, index: index, previous: previousInstrumentKind)
            // A barely read name is a guess, but not when it's the part these pages are already in.
            if result.kind == previousInstrumentKind, result.source != .continuation {
                result.confidence = max(result.confidence, PageItem.uncertainBelow)
            }
            results.append(result)
            if case .blank = result.kind {} else {
                previousInstrumentKind = result.kind
            }
        }
        return results
    }

    // MARK: - Fast paths

    /// Outline bookmarks whose labels match instruments become part boundaries directly —
    /// the most reliable signal available, when present.
    private func analyzeBookmarks(_ document: PDFDocument) -> [CachedPageResult]? {
        guard let root = document.outlineRoot, root.numberOfChildren > 0 else { return nil }

        var boundaries: [(pageIndex: Int, match: NameMatch)] = []
        for i in 0..<root.numberOfChildren {
            guard let child = root.child(at: i), let label = child.label,
                  let page = child.destination?.page,
                  let match = matcher.match(label)
            else { continue }
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { continue }
            boundaries.append((pageIndex, match))
        }
        guard boundaries.count >= 2 else { return nil }
        boundaries.sort { $0.pageIndex < $1.pageIndex }

        var results: [CachedPageResult] = []
        for (boundaryIndex, boundary) in boundaries.enumerated() {
            let end = boundaryIndex + 1 < boundaries.count ? boundaries[boundaryIndex + 1].pageIndex : document.pageCount
            for pageIndex in boundary.pageIndex..<end {
                results.append(CachedPageResult(
                    pageIndex: pageIndex,
                    kind: .instrument(boundary.match.primary),
                    extraInstruments: boundary.match.extras,
                    rotation: 0, cropRect: nil, detectedText: nil, confidence: 0.95,
                    source: pageIndex == boundary.pageIndex ? .bookmark : .continuation
                ))
            }
        }
        return results
    }

    /// A short document (≤4 pages) whose filename names an instrument is one part, whole.
    private func analyzeFilename(_ ref: DocumentRef, pageCount: Int) -> [CachedPageResult]? {
        let stem = FilenameParser.stripExtension((ref.url.lastPathComponent as NSString).lastPathComponent)
        let withoutTitle = stem.replacingOccurrences(of: ref.songTitle, with: "", options: .caseInsensitive)
        let parsed = FilenameParser.parse(FilenameParser.stripLeadingIndex(withoutTitle))

        if parsed.isScoreMarker {
            return (0..<pageCount).map {
                CachedPageResult(pageIndex: $0, kind: .score, extraInstruments: [], rotation: 0, cropRect: nil, detectedText: stem, confidence: 0.9, source: .filename)
            }
        }
        guard let match = matcher.match(parsed.matchText) else { return nil }
        return (0..<pageCount).map {
            CachedPageResult(pageIndex: $0, kind: .instrument(match.primary), extraInstruments: match.extras, rotation: 0, cropRect: nil, detectedText: stem, confidence: 0.9, source: .filename)
        }
    }

    // MARK: - Per-page analysis

    /// A page belongs to the part before it until a new name turns up in a top corner, where part
    /// names are printed. Anywhere else on a page, a word that happens to be an instrument is a
    /// title or a lyric. Only while no part has started yet is the rest of the page worth a look.
    private func analyzePage(_ page: PDFPage, index: Int, previous: PartKind?) async throws -> CachedPageResult {
        // Blank check first: cheap, and avoids wasting OCR on an empty page.
        if let raster = PageRasterizer.raster(page, longSide: 400),
           PageRasterizer.inkStats(raster).whiteFraction > 0.99 {
            return CachedPageResult(pageIndex: index, kind: .blank, extraInstruments: [], rotation: 0, cropRect: nil, detectedText: nil, confidence: 1, source: .continuation)
        }
        let isInsidePart = previous != nil && previous != .unassigned

        // Text layer first. Score pages are checked independently of the top-corner match: a
        // score page's top usually carries the song title, not an instrument name, so gating
        // score detection behind an instrument match would never fire.
        if TextExtractor.hasUsableTextLayer(page) {
            if isScorePage(page) {
                return CachedPageResult(pageIndex: index, kind: .score, extraInstruments: [], rotation: 0, cropRect: nil, detectedText: page.string, confidence: 0.9, source: .textLayer)
            }
            for text in TextExtractor.topCornerTexts(page) {
                if let (line, match) = firstNameInLines(of: text) {
                    return CachedPageResult(pageIndex: index, kind: .instrument(match.primary), extraInstruments: match.extras, rotation: 0, cropRect: nil, detectedText: line, confidence: 0.85, source: .textLayer)
                }
            }
            if !isInsidePart {
                if let text = TextExtractor.topBandText(page), let (line, match) = firstNameInLines(of: text) {
                    return CachedPageResult(pageIndex: index, kind: .instrument(match.primary), extraInstruments: match.extras, rotation: 0, cropRect: nil, detectedText: line, confidence: 0.85, source: .textLayer)
                }
                // Geometric selection can fail on engraved music even when the page has perfectly
                // good text; fall back to the whole page's text before trying OCR.
                if let whole = page.string, let match = matcher.match(whole) {
                    return CachedPageResult(pageIndex: index, kind: .instrument(match.primary), extraInstruments: match.extras, rotation: 0, cropRect: nil, detectedText: whole, confidence: 0.7, source: .textLayer)
                }
            }
        }

        let (found, unmatchedLabel) = try await recognizeWithOCR(page, index: index, isInsidePart: isInsidePart)
        if let found { return found }

        // No name found: continue the previous part, or leave unassigned.
        if let previous {
            return CachedPageResult(pageIndex: index, kind: previous, extraInstruments: [], rotation: 0, cropRect: nil, detectedText: unmatchedLabel, confidence: 0.5, source: .continuation)
        }
        return CachedPageResult(pageIndex: index, kind: .unassigned, extraInstruments: [], rotation: 0, cropRect: nil, detectedText: unmatchedLabel, confidence: 0, source: .continuation)
    }

    /// The first line that names an instrument. Line by line, because a corner can also catch the
    /// top of the music, and words run together from several lines match things no line says.
    /// A scan's hidden text layer is full of fragments like "trO", which shouldn't count as "trombone".
    private func firstNameInLines(of text: String) -> (line: String, match: NameMatch)? {
        for line in text.split(whereSeparator: \.isNewline).map(String.init)
        where line.filter(\.isLetter).count >= 4 || line.contains(where: \.isNumber) {
            if let match = matcher.match(line) { return (line, match) }
        }
        return nil
    }

    // MARK: - OCR

    /// OCR always starts with just the top of the page. Besides being faster, this is what makes
    /// it work: given a whole page of notation, Vision sometimes settles on the wrong orientation
    /// and reads even clean type upside down ("7068" as "8904"). Without the notation it doesn't.
    ///
    /// When nothing is recognized, also returns what's in the label's position, for Review to ask about.
    private func recognizeWithOCR(_ page: PDFPage, index: Int, isInsidePart: Bool) async throws -> (result: CachedPageResult?, unmatchedLabel: String?) {
        guard let raster = PageRasterizer.raster(page, longSide: 2400) else { return (nil, nil) }

        let bandHits = try await recognizeLabelBand(of: raster)
        if let found = classification(of: bandHits, index: index, rotation: 0, isInsidePart: isInsidePart) { return (found, nil) }
        let label = bandHits.filter(isInLabelColumn).first(where: isReadableWord)

        // Further down the page: a score's title page, or the instrument names up a score's left side.
        let hits = try await ocr.recognize(raster)
        if hits.contains(where: { $0.box.minY > 0.65 && FilenameParser.isScoreLabel($0.text) }) || isScorePage(hits) {
            return (CachedPageResult(pageIndex: index, kind: .score, extraInstruments: [], rotation: 0, cropRect: nil, detectedText: nil, confidence: 0.75, source: .ocr), nil)
        }

        // Real scans can have their content rotated within the crop box without setting /Rotate
        // at all. Skipped once the band holds a readable word: that page is the right way up.
        if !bandHits.contains(where: isReadableWord) {
            for rotation in [90, 180, 270] {
                let turned = PageRasterizer.rotated(raster, by: rotation)
                let turnedHits = try await recognizeLabelBand(of: turned)
                if let found = classification(of: turnedHits, index: index, rotation: rotation, isInsidePart: isInsidePart) { return (found, nil) }
            }
        }

        // As a last resort, hand what looks like the label to the on-device Apple Intelligence
        // model, which can recognize a name through garbling the matcher rejects. Only ever text
        // in the label's position: otherwise it picks an instrument for a title or a composer.
        if let intelligentMatcher, let label {
            if #available(macOS 26.0, *), let instrumentID = await intelligentMatcher.match(label.text) {
                return (CachedPageResult(pageIndex: index, kind: .instrument(instrumentID), extraInstruments: [], rotation: 0, cropRect: nil, detectedText: label.text, confidence: 0.55, source: .intelligentOCR), nil)
            }
        }
        return (nil, label?.text)
    }

    /// OCR of a raster's top band, left-most first, with boxes in whole-page coordinates.
    private func recognizeLabelBand(of raster: PageRaster) async throws -> [TextHit] {
        let hits = try await ocr.recognize(PageRasterizer.topBand(raster, fraction: LabelPosition.bandHeight))
        return hits
            .map { hit in
                var box = hit.box
                box.origin.y = (1 - LabelPosition.bandHeight) + box.minY * LabelPosition.bandHeight
                box.size.height *= LabelPosition.bandHeight
                return TextHit(text: hit.text, confidence: hit.confidence, box: box)
            }
            .sorted { $0.box.minX < $1.box.minX }
    }

    /// The most confident instrument (ties going to the left-most, where part names are printed)
    /// or score label among `hits`. Every hit is considered because the left-most text in the band
    /// is often a tempo marking or a library stamp, not the name. Inside a part, a new name has to
    /// be in a top corner, or be a line of its own: some editions centre it, but a line between the
    /// corners that merely has an instrument in it is the title, on every page.
    private func classification(of hits: [TextHit], index: Int, rotation: Int, isInsidePart: Bool) -> CachedPageResult? {
        if let label = hits.first(where: { FilenameParser.isScoreLabel($0.text) }) {
            return CachedPageResult(pageIndex: index, kind: .score, extraInstruments: [], rotation: rotation, cropRect: nil, detectedText: label.text, confidence: 0.8, source: .ocr)
        }

        var best: (hit: TextHit, match: NameMatch)?
        for hit in hits where !isInsidePart || isInTopCorner(hit) || matcher.isOnlyAName(hit.text) {
            guard let match = matcher.matchOCR(hit.text, allowWordRepair: isInLabelColumn(hit)) else { continue }
            if match.confidence > (best?.match.confidence ?? 0) { best = (hit, match) }
        }
        guard let best else { return nil }
        return CachedPageResult(pageIndex: index, kind: .instrument(best.match.primary), extraInstruments: best.match.extras, rotation: rotation, cropRect: nil, detectedText: best.hit.text, confidence: min(best.match.confidence, 0.75), source: .ocr)
    }

    private nonisolated func isInLabelColumn(_ hit: TextHit) -> Bool {
        hit.box.minX < LabelPosition.cornerWidth
    }

    /// By its centre, since a centred title can be wide enough to reach into a corner.
    private nonisolated func isInTopCorner(_ hit: TextHit) -> Bool {
        hit.box.midX < LabelPosition.cornerWidth || hit.box.midX > 1 - LabelPosition.cornerWidth
    }

    private nonisolated func isReadableWord(_ hit: TextHit) -> Bool {
        hit.confidence >= 0.5 && hit.text.filter(\.isLetter).count >= 4
    }

    /// The same five-distinct-instruments test as `isScorePage(_: PDFPage)`, on OCR hits.
    private func isScorePage(_ hits: [TextHit]) -> Bool {
        let matches = hits.filter { $0.box.minX < 0.2 }.compactMap { matcher.match($0.text) }
        return ScoreDetector.isScorePage(matches: matches)
    }

    /// Counts distinct instruments named anywhere in the page's text layer (the left 20% strip,
    /// where a score lists every part, falling back to the whole page if that geometric
    /// selection comes up empty) to decide whether this is a full-score page.
    private func isScorePage(_ page: PDFPage) -> Bool {
        let source = TextExtractor.leftStripText(page) ?? page.string
        guard let source else { return false }
        let matches = source
            .split(whereSeparator: \.isNewline)
            .compactMap { matcher.match(String($0)) }
        return ScoreDetector.isScorePage(matches: matches)
    }}
