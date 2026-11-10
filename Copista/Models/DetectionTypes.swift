import Foundation
import CoreGraphics

/// A Sendable snapshot of an imported PDF, used to pass across actor boundaries without ever
/// exposing the non-Sendable PDFDocument/PDFPage types themselves.
nonisolated struct DocumentRef: Sendable, Hashable {
    let id: UUID
    let url: URL
    let songTitle: String
    let pageCount: Int
}

/// Raw grayscale image bytes for a rendered page or page region, used instead of CGImage so a
/// rasterized page can cross an actor boundary as plain Sendable data.
nonisolated struct PageRaster: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixels: Data   // 8-bit grayscale, row-major, top-left origin (matches CGImage convention)
}

/// A page's crop box and intrinsic rotation, captured off the actor that owns the PDFPage.
nonisolated struct PageGeometry: Sendable, Hashable {
    var cropBox: CGRect
    var rotation: Int   // the page's own /Rotate value, normalized to 0/90/180/270
}

/// A single OCR or text-layer hit: recognized text plus its normalized bounding box.
/// Lower-left origin, matching both PDF user space and Vision's NormalizedRect convention.
nonisolated struct TextHit: Sendable, Hashable {
    let text: String
    let confidence: Double
    let box: CGRect
}

/// The outcome of matching a piece of text against the instrument catalog.
nonisolated struct NameMatch: Sendable, Hashable {
    var primary: UUID
    var extras: [UUID] = []
    var confidence: Double
}

/// What DocumentAnalyzer decided for one page, before SongAssembler turns it into Parts.
nonisolated struct PageAnalysis: Sendable, Hashable {
    var pageIndex: Int
    var rotation: Int
    var cropRect: CGRect?
    var detectedText: String?
    var confidence: Double
    var source: DetectionSource
    var match: NameMatch?
    var isScorePage: Bool
    var isBlank: Bool
}

/// The final, cacheable outcome for one page: enough to rebuild its Part membership without
/// rerunning detection. Keyed by file hash in CorrectionStore.
nonisolated struct CachedPageResult: Sendable, Codable, Hashable {
    var pageIndex: Int
    var kind: PartKind
    var extraInstruments: [UUID]
    var rotation: Int
    var cropRect: CGRect?
    var detectedText: String?
    var confidence: Double
    var source: DetectionSource
    /// Where the user has put this page within its part, if they've been editing it. Pages
    /// otherwise stay in the order of the file.
    var partPosition: Int?
}

nonisolated struct DocumentDetection: Sendable, Codable, Hashable {
    var sha256: String
    var pages: [CachedPageResult]
    /// `SettingsStore.catalogSignature` at the time of detection. Results go stale when the
    /// catalog changes (a remembered alias should apply) or the analyzer improves.
    var catalogSignature: String?
}

/// Progress events emitted by DocumentAnalyzer while it works, consumed on the main actor to
/// drive the "Analyzing %@…" label.
nonisolated enum DetectionProgress: Sendable {
    case started(documentID: UUID, title: String, pageCount: Int)
    case page(documentID: UUID, index: Int)
    case finished(documentID: UUID)
}
