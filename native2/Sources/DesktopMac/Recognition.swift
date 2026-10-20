import CoreGraphics
import DesktopProtocol
import Foundation
import Vision

// Ported from the native client's ocr.swift, so recognized_text reads as it did.

private let maximumRecognizedLines = 300
private let maximumRecognizedBytes = 16_000

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

extension Mac {
	/// Text Apple Vision recognized in a capture within `seconds`, keeping at most 300 lines and 16 KB of text;
	/// evidence about pixels, not Accessibility data. `display` maps boxes to global desktop points for a
	/// whole-display capture.
	public static func recognizeText(in image: CGImage, display: CGRect? = nil, seconds: Double) async -> JSON {
		var result: [(String, JSON)] = [
			("source", "Apple Vision text recognition, accurate level, on this Mac"),
			("note", "Recognized from pixels, not read from the app: text can be misread, merged or missed, and is not ground truth. Boxes are fractions of the screenshot from its top-left corner, so a box's center is a pointer point."),
			("lines", []),
		]
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
			result.append(("error", JSON("Text recognition failed: \(message)")))
			return .object(result)
		case .timedOut:
			result.append(("error", JSON("Text recognition did not finish within \(Int(seconds.rounded())) seconds. The first recognition after a restart can take longer while Vision loads its model; retry once.")))
			return .object(result)
		}
		let ordered = readingOrder(found.map { line in
			// Vision boxes are normalized from the bottom-left corner.
			(line.text, line.confidence, CGRect(x: line.box.minX, y: 1 - line.box.maxY, width: line.box.width, height: line.box.height))
		})
		var lines: [JSON] = []
		var bytes = 0
		for line in ordered {
			bytes += line.text.utf8.count
			guard lines.count < maximumRecognizedLines, bytes <= maximumRecognizedBytes else {
				result.append(("truncated", true))
				result.append(("omitted", JSON(ordered.count - lines.count)))
				break
			}
			let round = { (value: CGFloat) in JSON((Double(value) * 10_000).rounded() / 10_000) }
			var fields: [(String, JSON)] = [
				("text", JSON(line.text)),
				("confidence", JSON((Double(line.confidence) * 100).rounded() / 100)),
				("box", .object([("x", round(line.box.minX)), ("y", round(line.box.minY)), ("width", round(line.box.width)), ("height", round(line.box.height))])),
			]
			if let display {
				fields.append(("bounds", .object([
					("x", JSON(Double((display.minX + line.box.minX * display.width).rounded()))),
					("y", JSON(Double((display.minY + line.box.minY * display.height).rounded()))),
					("width", JSON(Double((line.box.width * display.width).rounded()))),
					("height", JSON(Double((line.box.height * display.height).rounded()))),
				])))
			}
			lines.append(.object(fields))
		}
		result[2] = ("lines", .array(lines))
		return .object(result)
	}

	/// Top-to-bottom rows, left to right within a row; boxes are top-left normalized.
	private static func readingOrder(_ lines: [(text: String, confidence: Float, box: CGRect)]) -> [(text: String, confidence: Float, box: CGRect)] {
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
}
