import Foundation
import CoreGraphics

nonisolated struct SplitSuggestion: Sendable {
    /// Where to cut, as a lower-left-origin fraction of the page height (matching
    /// `PageItem.cropRect`'s convention): the top half is `y ∈ [cutFraction, 1]`.
    var cutFraction: Double
    var confidence: Double
}

/// Detects two-instruments-on-one-page layouts (old handwritten scans with, say, Horn 1 on the
/// top half and Horn 2 on the bottom).
nonisolated enum SplitDetector {

    /// A second instrument name sitting at the top of the lower half (minY 0.40–0.55,
    /// lower-left-origin) is a strong signal that the page holds two parts.
    static func nameBasedSplit(_ hits: [TextHit]) -> SplitSuggestion? {
        guard hits.contains(where: { (0.40...0.55).contains($0.box.minY) }) else { return nil }
        return SplitSuggestion(cutFraction: 0.5, confidence: 0.8)
    }

    /// A wide horizontal white band near the middle of the page — the gap between two parts —
    /// even when neither part's name is readable (handwriting).
    static func whiteBandSplit(_ raster: PageRaster) -> SplitSuggestion? {
        guard let topDownFraction = PageRasterizer.whitestBand(raster, in: 0.35...0.65) else { return nil }
        return SplitSuggestion(cutFraction: 1 - topDownFraction, confidence: 0.5)
    }

    /// Combines both signals: the white band gives the precise cut line; agreement from a name
    /// match raises confidence. A white band alone is still offered, at low confidence, so
    /// handwritten pages with no readable name still get a split suggestion in Review.
    static func detectSplit(hits: [TextHit], raster: PageRaster?) -> SplitSuggestion? {
        let nameFound = nameBasedSplit(hits) != nil
        guard let raster, let band = whiteBandSplit(raster) else {
            return nameBasedSplit(hits)
        }
        return SplitSuggestion(cutFraction: band.cutFraction, confidence: nameFound ? 0.9 : 0.5)
    }

    static func cropRects(forCutAt cutFraction: Double) -> (top: CGRect, bottom: CGRect) {
        let top = CGRect(x: 0, y: cutFraction, width: 1, height: 1 - cutFraction)
        let bottom = CGRect(x: 0, y: 0, width: 1, height: cutFraction)
        return (top, bottom)
    }
}
