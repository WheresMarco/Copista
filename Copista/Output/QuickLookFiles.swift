import Foundation
import CoreGraphics

/// The Quick Look panel shows files, not pages of one, so each page gets its own one-page PDF.
/// They're drawn by `OutputBuilder`, which makes the panel show a page exactly as it would print.
nonisolated enum QuickLookFiles {
    struct Page: Sendable, Identifiable {
        let id: UUID
        let documentURL: URL
        let pageIndex: Int
        let rotation: Int
        let cropRect: CGRect?
        /// Shown as the title of the panel, so it's what the file is named.
        let title: String
    }

    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CopistaQuickLook", isDirectory: true)
    }

    /// Named so that a page that's been rotated or moved to another part gets a new file.
    static func url(for page: Page, in directory: URL = directory) -> URL {
        let name = page.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return directory
            .appendingPathComponent(page.id.uuidString, isDirectory: true)
            .appendingPathComponent(String(page.rotation), isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension("pdf")
    }

    /// Makes sure a file exists for every page, returning their URLs in the same order.
    static func prepare(_ pages: [Page], in directory: URL = directory) async throws -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []
        for page in pages {
            let url = url(for: page, in: directory)
            if !fm.fileExists(atPath: url.path) {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let sheet = SheetSpec(documentURL: page.documentURL, pageIndex: page.pageIndex, rotation: page.rotation, cropRect: page.cropRect)
                try await OutputBuilder().build(OutputPlan(sheets: [sheet]), to: url)
            }
            urls.append(url)
        }
        return urls
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
