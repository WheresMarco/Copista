import Foundation
import PDFKit

/// Where on a page a part's name is printed, as shares of the page.
nonisolated enum LabelPosition {
    /// How far down from the top.
    static let bandHeight = 0.22
    /// How far in from the left or right edge. The middle has the title.
    static let cornerWidth = 0.35
}

/// Pulls text out of a PDF page's text layer, restricted to where instrument names are printed.
nonisolated enum TextExtractor {

    static func hasUsableTextLayer(_ page: PDFPage) -> Bool {
        guard let text = page.string else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What's printed in the top left and top right corners, left first: where a part's name goes.
    static func topCornerTexts(_ page: PDFPage) -> [String] {
        guard let band = topBand(of: page) else { return [] }
        let cornerWidth = band.width * LabelPosition.cornerWidth
        let corners = [
            CGRect(x: band.minX, y: band.minY, width: cornerWidth, height: band.height),
            CGRect(x: band.maxX - cornerWidth, y: band.minY, width: cornerWidth, height: band.height),
        ]
        return corners.compactMap { usableText(page.selection(for: $0)) }
    }

    /// Everything across the top of the page, corners and middle.
    static func topBandText(_ page: PDFPage) -> String? {
        guard let band = topBand(of: page) else { return nil }
        return usableText(page.selection(for: band))
    }

    private static func topBand(of page: PDFPage) -> CGRect? {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let height = bounds.height * LabelPosition.bandHeight
        return CGRect(x: bounds.minX, y: bounds.maxY - height, width: bounds.width, height: height)
    }

    /// The left 20% strip of the whole page, used by ScoreDetector to count distinct
    /// instrument names on a score page without reading the entire page.
    static func leftStripText(_ page: PDFPage) -> String? {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let rect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width * 0.2, height: bounds.height)
        return usableText(page.selection(for: rect))
    }

    private static func usableText(_ selection: PDFSelection?) -> String? {
        guard let text = selection?.string else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }
}
