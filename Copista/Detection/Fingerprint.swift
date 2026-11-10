import Foundation
import CryptoKit

nonisolated enum Fingerprint {
    /// Hashes a file's contents in chunks so large scans don't need to be held in memory at once.
    /// `@concurrent` moves this off whatever actor called it (typically the main actor), since
    /// it's a plain, stateless, CPU/IO-bound leaf with no isolated state to protect.
    @concurrent
    static func sha256(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) // 1 MB
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
