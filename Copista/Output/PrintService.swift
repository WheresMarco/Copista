import Foundation
import AppKit
import PDFKit

@MainActor
enum PrintService {
    enum PrintError: LocalizedError {
        case cannotStart

        var errorDescription: String? {
            String(localized: "The print dialog couldn't be opened. Try Save PDF… instead.")
        }
    }

    /// Each song as a print job of its own, so they come out as separate stacks. The print dialog
    /// is shown once, for the first, and what's chosen there is used for the rest.
    static func print(_ documents: [(title: String, document: PDFDocument)]) throws {
        guard let first = documents.first, let firstJob = Self.operation(for: first.document) else { throw PrintError.cannotStart }
        firstJob.jobTitle = first.title
        guard firstJob.run() else { return }

        let chosen = firstJob.printInfo
        let savedTo = chosen.jobDisposition == .save ? chosen.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] as? URL : nil
        for (title, document) in documents.dropFirst() {
            let info = chosen.copy() as! NSPrintInfo
            // "Save as PDF" in the dialog: a file per song next to the first, not one overwriting it.
            if let savedTo {
                info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = savedTo.deletingLastPathComponent()
                    .appendingPathComponent(title.replacingOccurrences(of: "/", with: "-")).appendingPathExtension("pdf")
            }
            guard let next = Self.operation(for: document, printInfo: info) else { continue }
            next.jobTitle = title
            next.showsPrintPanel = false
            next.run()
        }
    }

    /// The sheets are already composed as A4 with their own margin, so they're printed 1:1.
    static func operation(for document: PDFDocument?, printInfo: NSPrintInfo = NSPrintInfo.shared.copy() as! NSPrintInfo) -> NSPrintOperation? {
        printInfo.paperSize = SheetLayout.a4Portrait
        printInfo.topMargin = 0
        printInfo.bottomMargin = 0
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0
        return document?.printOperation(for: printInfo, scalingMode: .pageScaleNone, autoRotate: true)
    }

    /// Writes the data to a temp file and opens it in Preview, returning the temp file's URL.
    static func openInPreview(data: Data, suggestedName: String) throws -> URL {
        let safeName = suggestedName.isEmpty ? "Print" : suggestedName
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(safeName)
            .appendingPathExtension("pdf")
        try data.write(to: tempURL, options: .atomic)
        NSWorkspace.shared.open(tempURL)
        return tempURL
    }
}
