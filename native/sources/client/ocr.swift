import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Text that Apple Vision recognized in a captured image; evidence about pixels, not Accessibility data.
struct RecognizedText: Encodable {
	struct Box: Encodable {
		let x: Double
		let y: Double
		let width: Double
		let height: Double
	}

	struct Line: Encodable {
		let text: String
		let confidence: Double
		/// Normalized to the screenshot, from its top-left corner, as pointer points are.
		let box: Box
		/// Global desktop points, only for a whole-display capture.
		let bounds: Bounds?
	}

	var source = "Apple Vision text recognition, accurate level, on this Mac"
	var note =
		"Recognized from pixels, not read from the app: text can be misread, merged or missed, and is not ground truth. Boxes are fractions of the screenshot from its top-left corner, so a box's center is a pointer point."
	var lines: [Line] = []
	var truncated: Bool?
	var omitted: Int?
	var error: String?
}

private enum Recognition: @unchecked Sendable {
	case lines([(text: String, confidence: Float, box: CGRect)])
	case failed(String)
	case timedOut
}

/// Resumes its continuation once: with the recognition, its failure, or the deadline.
private final class RecognitionRace: @unchecked Sendable {
	private let lock = NSLock()
	private var continuation: CheckedContinuation<Recognition, Never>?

	init(_ continuation: CheckedContinuation<Recognition, Never>) {
		self.continuation = continuation
	}

	func finish(_ value: Recognition) {
		lock.lock()
		let pending = continuation
		continuation = nil
		lock.unlock()
		pending?.resume(returning: value)
	}
}

/// Set when the client starts; recognition must finish before the caller's 30-second deadline.
nonisolated(unsafe) var clientStarted = Date()

/// Recognition time left after the observation, at most 8 seconds.
func recognitionSeconds() -> Double {
	max(1, min(8, 26 - Date().timeIntervalSince(clientStarted)))
}

let maximumRecognizedLines = 300
let maximumRecognizedBytes = 16_000

/// Recognizes text in an image file within `seconds`, keeping at most 300 lines and 16 KB of text.
/// `display` maps boxes to global desktop points for a whole-display capture.
func recognizeText(at path: String, display: CGRect? = nil, seconds: Double) async -> RecognizedText {
	var result = RecognizedText()
	guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
		let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0
	else {
		result.error = "The captured image could not be decoded for text recognition."
		return result
	}
	let request = VNRecognizeTextRequest()
	request.recognitionLevel = .accurate
	request.usesLanguageCorrection = true
	nonisolated(unsafe) let vision = request
	let recognition = await withCheckedContinuation { (continuation: CheckedContinuation<Recognition, Never>) in
		let race = RecognitionRace(continuation)
		DispatchQueue.global(qos: .userInitiated).async {
			do {
				try VNImageRequestHandler(cgImage: image, options: [:]).perform([vision])
				race.finish(.lines((vision.results ?? []).compactMap { observation in
					guard let candidate = observation.topCandidates(1).first else { return nil }
					let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
					return text.isEmpty ? nil : (text, candidate.confidence, observation.boundingBox)
				}))
			} catch {
				race.finish(.failed(error.localizedDescription))
			}
		}
		// The process exits after replying, so recognition abandoned here cannot outlive the request.
		DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
			vision.cancel()
			race.finish(.timedOut)
		}
	}
	let found: [(text: String, confidence: Float, box: CGRect)]
	switch recognition {
	case let .lines(lines):
		found = lines
	case let .failed(message):
		result.error = "Text recognition failed: \(message)"
		return result
	case .timedOut:
		result.error = "Text recognition did not finish within \(Int(seconds.rounded())) seconds. The first recognition after a restart can take longer while Vision loads its model; retry once."
		return result
	}
	let ordered = readingOrder(found.map { line in
		// Vision boxes are normalized from the bottom-left corner.
		(line.text, line.confidence, CGRect(
			x: line.box.minX, y: 1 - line.box.maxY, width: line.box.width, height: line.box.height
		))
	})
	var bytes = 0
	for line in ordered {
		bytes += line.text.utf8.count
		guard result.lines.count < maximumRecognizedLines, bytes <= maximumRecognizedBytes else {
			result.truncated = true
			result.omitted = ordered.count - result.lines.count
			break
		}
		let round = { (value: CGFloat) in (Double(value) * 10_000).rounded() / 10_000 }
		result.lines.append(.init(
			text: line.text,
			confidence: (Double(line.confidence) * 100).rounded() / 100,
			box: .init(x: round(line.box.minX), y: round(line.box.minY), width: round(line.box.width), height: round(line.box.height)),
			bounds: display.map { display in
				Bounds(CGRect(
					x: (display.minX + line.box.minX * display.width).rounded(),
					y: (display.minY + line.box.minY * display.height).rounded(),
					width: (line.box.width * display.width).rounded(),
					height: (line.box.height * display.height).rounded()
				))
			}
		))
	}
	return result
}

/// Top-to-bottom rows, left to right within a row; boxes are top-left normalized.
func readingOrder(_ lines: [(text: String, confidence: Float, box: CGRect)])
	-> [(text: String, confidence: Float, box: CGRect)]
{
	let sorted = lines.sorted { $0.box.midY < $1.box.midY }
	var rows: [[(text: String, confidence: Float, box: CGRect)]] = []
	for line in sorted {
		// A line joins the current row when its center lies within the row's first line.
		if let first = rows.last?.first, line.box.midY <= first.box.maxY, line.box.midY >= first.box.minY {
			rows[rows.count - 1].append(line)
		} else {
			rows.append([line])
		}
	}
	return rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
}
