import Foundation
import PDFKit
import CoreGraphics

nonisolated extension PageRaster {
    var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

nonisolated struct InkStats: Sendable {
    var whiteFraction: Double   // fraction of pixels at or above the "white" threshold
}

/// Renders PDF pages into plain grayscale byte buffers and analyzes them for blank-page and
/// split-line detection. Every function here is synchronous and `nonisolated`: taking a
/// non-Sendable `PDFPage` is safe specifically because a synchronous nonisolated function
/// crosses no actor boundary — it simply runs on whatever executor called it (in practice,
/// always `DocumentAnalyzer`'s own actor, which owns the `PDFPage` to begin with).
nonisolated enum PageRasterizer {

    /// Renders a page to an 8-bit grayscale raster as it appears on screen: its /Rotate flag
    /// applied, row 0 at the visual top. Scaled so its longer side measures `longSide`.
    static func raster(_ page: PDFPage, longSide: CGFloat) -> PageRaster? {
        guard let cgPage = page.pageRef else { return nil }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let isQuarterTurned = SheetLayout.quarter(page.rotation) % 180 != 0
        let visual = isQuarterTurned ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let scale = longSide / max(visual.width, visual.height)
        let width = max(1, Int((visual.width * scale).rounded()))
        let height = max(1, Int((visual.height * scale).rounded()))

        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // A bitmap context's default CTM is already y-up with row 0 at the top of the image, the
        // same orientation as PDF space, so no flip is needed. `getDrawingTransform` handles
        // /Rotate and the crop box origin, but never scales up — hence the separate scale.
        ctx.scaleBy(x: CGFloat(width) / visual.width, y: CGFloat(height) / visual.height)
        ctx.concatenate(cgPage.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: visual), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(cgPage)

        guard let data = ctx.data else { return nil }
        return PageRaster(width: width, height: height, bytesPerRow: width, pixels: Data(bytes: data, count: width * height))
    }

    /// The top `fraction` of a raster: row 0 is the page's visual top, so this is just its first rows.
    static func topBand(_ raster: PageRaster, fraction: Double) -> PageRaster {
        let rows = max(1, min(raster.height, Int(Double(raster.height) * fraction)))
        return PageRaster(width: raster.width, height: rows, bytesPerRow: raster.bytesPerRow, pixels: raster.pixels.prefix(rows * raster.bytesPerRow))
    }

    static func inkStats(_ raster: PageRaster) -> InkStats {
        guard !raster.pixels.isEmpty else { return InkStats(whiteFraction: 1) }
        var white = 0
        raster.pixels.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for byte in buf where byte >= 250 { white += 1 }
        }
        return InkStats(whiteFraction: Double(white) / Double(raster.pixels.count))
    }

    /// Finds the vertical centre of the whitest horizontal band of at least 1.5% of the page
    /// height, searching only within `range`. Both `range` and the returned fraction are
    /// **top-down** (0 = top of page, 1 = bottom) to match the raster's own row order; callers
    /// that build a lower-left-origin `PageItem.cropRect` must flip with `1 - value`.
    static func whitestBand(_ raster: PageRaster, in range: ClosedRange<Double>) -> Double? {
        guard raster.height > 0, raster.width > 0 else { return nil }
        let minBandRows = max(1, Int(0.015 * Double(raster.height)))
        let rowStart = max(0, Int(range.lowerBound * Double(raster.height)))
        let rowEnd = min(raster.height, Int(range.upperBound * Double(raster.height)))
        guard rowEnd - rowStart >= minBandRows else { return nil }

        var rowWhiteness: [Double] = []
        raster.pixels.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for row in rowStart..<rowEnd {
                var sum = 0
                let base = row * raster.bytesPerRow
                for col in 0..<raster.width { sum += Int(buf[base + col]) }
                rowWhiteness.append(Double(sum) / Double(raster.width))
            }
        }

        var bestStart = 0
        var bestAverage = -1.0
        var windowSum = rowWhiteness[0..<minBandRows].reduce(0, +)
        for start in 0...(rowWhiteness.count - minBandRows) {
            if start > 0 {
                windowSum += rowWhiteness[start + minBandRows - 1] - rowWhiteness[start - 1]
            }
            let average = windowSum / Double(minBandRows)
            if average > bestAverage {
                bestAverage = average
                bestStart = start
            }
        }
        let centreRow = rowStart + bestStart + minBandRows / 2
        return Double(centreRow) / Double(raster.height)
    }

    /// Rotates a raster's pixel buffer in-memory by a quarter turn. Used to try OCR again on a
    /// portrait page when the upright orientation found no readable label — a pure pixel-buffer
    /// operation, decoupled from PDFKit, so both 90° and 270° can be tried cheaply without
    /// re-rendering the page from the PDF.
    static func rotated(_ raster: PageRaster, by degrees: Int) -> PageRaster {
        let turn = SheetLayout.quarter(degrees)
        guard turn != 0 else { return raster }

        let w = raster.width, h = raster.height
        let newWidth = turn == 180 ? w : h
        let newHeight = turn == 180 ? h : w
        var newPixels = [UInt8](repeating: 255, count: newWidth * newHeight)

        raster.pixels.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for y in 0..<h {
                for x in 0..<w {
                    let value = buf[y * raster.bytesPerRow + x]
                    let destination: (x: Int, y: Int)
                    switch turn {
                    case 90: destination = (h - 1 - y, x)
                    case 180: destination = (w - 1 - x, h - 1 - y)
                    default: destination = (y, w - 1 - x)   // 270
                    }
                    newPixels[destination.y * newWidth + destination.x] = value
                }
            }
        }
        return PageRaster(width: newWidth, height: newHeight, bytesPerRow: newWidth, pixels: Data(newPixels))
    }
}
