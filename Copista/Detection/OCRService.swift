import Foundation
import Vision
import CoreGraphics

/// Wraps Vision's text recognition. An actor because it holds request configuration that
/// should be built once and reused, and because `RecognizeTextRequest.perform(on:)` is a
/// framework `async` function that genuinely suspends off whatever actor calls it — this is
/// where OCR work actually leaves the main actor.
actor OCRService {
    private var request: RecognizeTextRequest

    init(
        languages: [String] = ["sv-SE", "en-US", "de-DE", "nb-NO"],
        level: RecognizeTextRequest.RecognitionLevel = .accurate
    ) {
        var request = RecognizeTextRequest()
        request.recognitionLevel = level
        request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
        request.usesLanguageCorrection = false
        self.request = request
    }

    /// Recognizes text in a rendered page raster. Returns every observation Vision found, each
    /// with a normalized, lower-left-origin bounding box — callers filter to a region of
    /// interest (e.g. the top 15% of the page) themselves.
    func recognize(_ raster: PageRaster) async throws -> [TextHit] {
        guard let cgImage = raster.cgImage else { return [] }
        let observations = try await request.perform(on: cgImage)
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox.toImageCoordinates(CGSize(width: 1, height: 1))
            return TextHit(text: candidate.string, confidence: Double(candidate.confidence), box: box)
        }
    }
}
