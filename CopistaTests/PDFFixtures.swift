import Foundation
import AppKit
import CoreText
import PDFKit
@testable import Copista

/// Builds small PDFs on disk for tests, so the pipeline can be exercised end to end without
/// depending on anyone's real library.
enum PDFFixtures {
    static let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)

    /// A scratch directory unique to one test; callers don't need to clean it up, it lives in tmp.
    static func directory(_ name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopistaFixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// One page per label, with the label as *pixels only* (no text layer) in the top-left corner,
    /// like a scan. An empty label makes a page with staves but no name; `nil` a truly blank page.
    static func scannedPDF(labels: [String?], at url: URL) throws {
        try writePDF(at: url, pageCount: labels.count) { ctx, index in
            guard let label = labels[index] else { return }
            ctx.draw(scanImage(label: label), in: a4)
        }
    }

    /// One page per label, with the label as real text in the top-left corner.
    static func textPDF(labels: [String], at url: URL) throws {
        try writePDF(at: url, pageCount: labels.count) { ctx, index in
            draw(labels[index], at: CGPoint(x: 40, y: a4.height - 60), size: 22, in: ctx)
            drawStaves(in: ctx, width: a4.width, height: a4.height - 120)
        }
    }

    enum TopPosition {
        case left, middle, right
    }

    /// One page per entry, with whatever's listed printed along its top, and notation below. As real
    /// text, or as pixels only if `asScan`.
    static func headedPDF(pages: [[(text: String, position: TopPosition)]], asScan: Bool, bodyText: String? = nil, at url: URL) throws {
        func drawPage(_ headings: [(text: String, position: TopPosition)], in ctx: CGContext) {
            for heading in headings {
                let width = CTLineGetTypographicBounds(line(heading.text, size: 22), nil, nil, nil)
                let x: CGFloat
                switch heading.position {
                case .left: x = 40
                case .middle: x = (a4.width - width) / 2
                case .right: x = a4.width - 40 - width
                }
                draw(heading.text, at: CGPoint(x: x, y: a4.height - 60), size: 22, in: ctx)
            }
            drawStaves(in: ctx, width: a4.width, height: a4.height - 120)
            if let bodyText { draw(bodyText, at: CGPoint(x: 200, y: a4.height / 2), size: 14, in: ctx) }
        }
        try writePDF(at: url, pageCount: pages.count) { ctx, index in
            guard asScan else { return drawPage(pages[index], in: ctx) }
            let scale = 2
            let width = Int(a4.width) * scale, height = Int(a4.height) * scale
            let scan = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            scan.setFillColor(gray: 1, alpha: 1)
            scan.fill(CGRect(x: 0, y: 0, width: width, height: height))
            scan.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            drawPage(pages[index], in: scan)
            ctx.draw(scan.makeImage()!, in: a4)
        }
    }

    /// One page filled black across its visually top 10%, for orientation checks.
    static func topBandPDF(at url: URL, rotation: Int = 0) throws {
        // Draw the band where it will end up on top *after* the /Rotate flag is applied.
        try writePDF(at: url, pageCount: 1) { ctx, _ in
            ctx.setFillColor(gray: 0, alpha: 1)
            switch rotation {
            case 90: ctx.fill(CGRect(x: 0, y: 0, width: a4.width * 0.1, height: a4.height))
            case 180: ctx.fill(CGRect(x: 0, y: 0, width: a4.width, height: a4.height * 0.1))
            case 270: ctx.fill(CGRect(x: a4.width * 0.9, y: 0, width: a4.width * 0.1, height: a4.height))
            default: ctx.fill(CGRect(x: 0, y: a4.height * 0.9, width: a4.width, height: a4.height * 0.1))
            }
        }
        guard rotation != 0 else { return }
        let document = try unwrap(PDFDocument(url: url))
        document.page(at: 0)?.rotation = rotation
        // Written aside and swapped in: PDFKit can't reliably overwrite the file it's reading from.
        let rotated = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".pdf")
        guard document.write(to: rotated) else { throw FixtureError() }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: rotated)
    }

    /// Reads back how dark the top and bottom 5% of a rendered PDF page are (0 = white, 1 = black),
    /// as a human looking at the page would see them.
    static func topAndBottomInk(ofPage index: Int, in url: URL) throws -> (top: Double, bottom: Double) {
        let page = try unwrap(PDFDocument(url: url)?.page(at: index))
        let raster = try unwrap(PageRasterizer.raster(page, longSide: 200))
        return (ink(raster, rows: 0..<raster.height / 20), ink(raster, rows: raster.height * 19 / 20..<raster.height))
    }

    static func ink(_ raster: PageRaster, rows: Range<Int>) -> Double {
        var sum = 0
        raster.pixels.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for row in rows {
                for col in 0..<raster.width { sum += 255 - Int(buf[row * raster.bytesPerRow + col]) }
            }
        }
        return Double(sum) / Double(max(1, rows.count * raster.width) * 255)
    }

    // MARK: - Drawing

    private struct FixtureError: Error {}

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw FixtureError() }
        return value
    }

    private static func writePDF(at url: URL, pageCount: Int, draw: (CGContext, Int) -> Void) throws {
        var box = a4
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw FixtureError() }
        for index in 0..<pageCount {
            ctx.beginPDFPage(nil)
            draw(ctx, index)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private static func scanImage(label: String) -> CGImage {
        let scale = 2
        let width = Int(a4.width) * scale, height = Int(a4.height) * scale
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        draw(label, at: CGPoint(x: 40, y: a4.height - 60), size: 22, in: ctx)
        drawStaves(in: ctx, width: a4.width, height: a4.height - 120)
        return ctx.makeImage()!
    }

    private static func drawStaves(in ctx: CGContext, width: CGFloat, height: CGFloat) {
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(0.6)
        var y = height
        while y > 60 {
            for line in 0..<5 {
                ctx.move(to: CGPoint(x: 40, y: y - CGFloat(line) * 6))
                ctx.addLine(to: CGPoint(x: width - 40, y: y - CGFloat(line) * 6))
            }
            ctx.strokePath()
            y -= 80
        }
    }

    private static func line(_ text: String, size: CGFloat) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, in ctx: CGContext) {
        ctx.textPosition = point
        CTLineDraw(line(text, size: size), ctx)
    }
}
