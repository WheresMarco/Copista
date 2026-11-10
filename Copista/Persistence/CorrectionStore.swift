import Foundation
import Observation

/// Remembers detection results (keyed by file hash) and song-grouping overrides (keyed by
/// source directory), so re-importing a file the user has already reviewed skips detection
/// entirely, and a folder the user regrouped stays regrouped.
@Observable
@MainActor
final class CorrectionStore {
    private(set) var detections: [String: DocumentDetection] = [:]
    private(set) var songTitleOverrides: [String: String] = [:]

    private let fileURL: URL

    init(directory: URL = CorrectionStore.applicationSupportDirectory()) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("corrections.json")

        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(File.self, from: data) {
            detections = saved.detections
            songTitleOverrides = saved.songTitleOverrides
        }
    }

    /// A saved result that can still be trusted: every instrument it names must still exist, and
    /// it must come from the current catalog — unless the user has reviewed it, which always stands.
    func detection(forHash hash: String, signature: String, knownInstruments: Set<UUID>) -> DocumentDetection? {
        guard let detection = detections[hash] else { return nil }
        let namesKnownInstruments = detection.pages.allSatisfy { page in
            guard case .instrument(let id) = page.kind else { return true }
            return knownInstruments.contains(id) && page.extraInstruments.allSatisfy(knownInstruments.contains)
        }
        guard namesKnownInstruments else { return nil }
        let isReviewed = detection.pages.contains { $0.source == .manual || $0.partPosition != nil }
        return isReviewed || detection.catalogSignature == signature ? detection : nil
    }

    func save(_ detection: DocumentDetection) {
        detections[detection.sha256] = detection
        persist()
    }

    func songTitleOverride(forDirectory path: String) -> String? {
        songTitleOverrides[path]
    }

    func setSongTitleOverride(_ title: String, forDirectory path: String) {
        songTitleOverrides[path] = title
        persist()
    }

    private func persist() {
        let file = File(detections: detections, songTitleOverrides: songTitleOverrides)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    nonisolated private static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Copista", isDirectory: true)
    }

    private struct File: Codable {
        var detections: [String: DocumentDetection]
        var songTitleOverrides: [String: String]
    }
}
