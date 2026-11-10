import Foundation
import PDFKit
import CoreGraphics

/// Draws an `OutputPlan` to a PDF file. An actor because a PDF `CGContext` is inherently
/// serial — pages must be written in order into one open context — and because it caches the
/// `PDFDocument`s it opens for the duration of one build; both stay actor-local and never cross
/// a boundary.
actor OutputBuilder {
    enum BuildError: LocalizedError {
        case cannotCreateContext
        case cannotOpenDocument(URL)
        case cannotOpenPage

        var errorDescription: String? {
            switch self {
            case .cannotCreateContext: String(localized: "The print file couldn't be created.")
            case .cannotOpenDocument(let url): String(localized: "“\(url.lastPathComponent)” couldn't be opened. Has it been moved?")
            case .cannotOpenPage: String(localized: "A page couldn't be read from its PDF.")
            }
        }
    }

    func build(_ plan: OutputPlan, to destination: URL) async throws {
        var cache: [URL: PDFDocument] = [:]
        var mediaBox = CGRect(origin: .zero, size: SheetLayout.a4Portrait)

        guard let consumer = CGDataConsumer(url: destination as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw BuildError.cannotCreateContext }

        do {
            for sheet in plan.sheets {
                try Task.checkCancellation()

                guard let documentURL = sheet.documentURL else {
                    ctx.beginPDFPage(nil)
                    ctx.endPDFPage()
                    continue
                }

                let document: PDFDocument
                if let cached = cache[documentURL] {
                    document = cached
                } else {
                    guard let opened = PDFDocument(url: documentURL) else {
                        throw BuildError.cannotOpenDocument(documentURL)
                    }
                    cache[documentURL] = opened
                    document = opened
                }

                guard let page = document.page(at: sheet.pageIndex), let cgPage = page.pageRef else {
                    throw BuildError.cannotOpenPage
                }

                let geometry = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: SheetLayout.quarter(page.rotation))
                let sheetPlan = SheetLayout.plan(geometry: geometry, extraRotation: sheet.rotation, cropRect: sheet.cropRect)

                var box = CGRect(origin: .zero, size: sheetPlan.sheetSize)
                let boxData = withUnsafeBytes(of: &box) { Data($0) } as CFData
                ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
                ctx.saveGState()
                ctx.clip(to: sheetPlan.destRect)
                ctx.concatenate(sheetPlan.transform)
                ctx.drawPDFPage(cgPage)
                ctx.restoreGState()
                ctx.endPDFPage()
            }
        } catch {
            ctx.closePDF()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        ctx.closePDF()
    }
}
