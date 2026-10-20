import DesktopProtocol
import Foundation

// Ported from src/compact.ts (#144): the shape results take for a model, what an agent acts on, once. Native results
// carry detection metadata, timings, receipts already checked, duplicated fields and booleans spelled as strings;
// only the final result is made compact, so internal reads keep the full shape.

/// Native fields that describe how a result was produced, not what it found.
private let internalFields: Set = [
	"detection_metadata", "diagnostics", "timings", "coordinate_context", "element_count", "target_receipt",
	"requires_fresh_observation",
]

/// Fields of an element's attributes that repeat the element itself.
private let repeatedAttributes: Set = ["role", "isFocused", "isActionable", "axEnabledKnown", "isValueSettable"]

/// Attributes whose numbers arrive as strings.
private let numericAttributes: Set = ["depth", "disclosureLevel"]

/// The compact result text, or the text unchanged when it isn't JSON, as plain error text isn't.
public func compactResult(_ text: String, allWindows: Bool = false) -> String {
	guard let value = try? JSON(parsing: text) else { return text }
	return compact(value, allWindows: allWindows).text
}

public func compact(_ value: JSON, allWindows: Bool = false, key: String? = nil) -> JSON {
	if let items = value.array {
		if key == "ui_elements" || key == "elements", items.allSatisfy(isElement) { return .array(items.map(compactElement)) }
		if key == "windows" || key == "created_windows", items.allSatisfy(isWindowRow) { return .array(items.map(compactWindow)) }
		if key == "apps", items.allSatisfy(isAppRow) { return .array(items.map(compactApp)) }
		return .array(items.map { compact($0, allWindows: allWindows) })
	}
	guard let fields = value.pairs else { return value }
	if key == "application", isAppRow(value) { return compactApp(value) }
	if key == "window", isWindowRow(value) { return compactWindow(value) }
	var out = JSON.object([])
	for (name, field) in fields {
		if internalFields.contains(name) { continue }
		if field.array?.isEmpty == true, name.hasSuffix("warnings") { continue }
		if name == "inspection_mode", field == "accessibility" { continue }
		if name == "native_outcome" {
			// An expectation that matched keeps the native "unknown" it overrode.
			if field.string != nil { out.set(name, field) }
			// An unknown outcome is the one case where the agent decides whether repeating is safe.
			if value["outcome"] == "unknown", let retry = field["retry_safety"], retry.string != nil { out.set("retry_safety", retry) }
			continue
		}
		// An action echoes its own name and the snapshot it was given.
		if key == "action", name == "action" || name == "snapshot_id" { continue }
		if key == "image" || key == "system", name == "note" { continue }
		if name == "session" || name == "appearance", let pairs = field.pairs ?? field.array.map({ $0.enumerated().map { (String($0), $1) } }) {
			out.set(name, .object(pairs.filter { $0.1 != .bool(false) }))
			continue
		}
		if name == "windows", let rows = field.array, rows.allSatisfy(isWindowRow), !allWindows {
			let shown = rows.filter { !isStrip($0) }
			out.set(name, compact(.array(shown), allWindows: allWindows, key: name))
			if shown.count < rows.count { out.set("hidden_windows", JSON(rows.count - shown.count)) }
			continue
		}
		out.set(name, compact(field, allWindows: allWindows, key: name))
	}
	return out
}

/// JavaScript's truthiness for a field, absent counting as undefined.
private func truthy(_ value: JSON?) -> Bool {
	switch value {
	case nil, .null?, .bool(false)?: false
	case let .number(n)?: n != 0 && !n.isNaN
	case let .string(s)?: !s.isEmpty
	default: true
	}
}

private func isElement(_ value: JSON) -> Bool {
	value["id"]?.string != nil && (value["role"] != nil || value["attributes"] != nil)
}

private func isWindowRow(_ value: JSON) -> Bool {
	guard let target = value["target"], target.pairs != nil else { return false }
	return target["window_id"]?.number != nil
}

private func isAppRow(_ value: JSON) -> Bool {
	guard let target = value["target"], target.pairs != nil else { return false }
	return target["pid"]?.number != nil && target["window_id"] == nil
}

/// An untitled window macOS lists off screen and on no Space, such as an app's menu bar strips or a Finder desktop
/// helper. A window on another Space, minimized or hidden with its app keeps a Space or a reason, and stays listed.
private func isStrip(_ row: JSON) -> Bool {
	!truthy(row["window_title"]) && row["is_on_screen"] == .bool(false) && row["target"]?["is_minimized"] != .bool(true)
		&& (row["space_ids"]?.array?.isEmpty ?? true) && row["availability"]?["state"] != "available"
}

/// One element, once: its ID, role, label, value when it differs, bounds as [x, y, width, height] in whole points,
/// state only where it isn't the default, and its other attributes alongside, with real booleans and numbers.
private func compactElement(_ element: JSON) -> JSON {
	let attributes = element["attributes"] ?? .object([])
	// Peekaboo calls roles it doesn't name "other"; the Accessibility role says what they are.
	let role = element["role"] == nil || element["role"] == "other" ? attributes["role"] ?? element["role"] : element["role"]
	let label = element["label"]
	var out = JSON.object([("id", element["id"]!)])
	out.set("role", role)
	// Peekaboo labels an unnamed element with its role description, as "cell" for an AXCell.
	if let text = label?.string, !text.isEmpty, plain(label) != plain(role) { out.set("label", label) }
	if let value = element["value"], value != "", !strictlyEqual(value, label) { out.set("value", value) }
	if let bounds = element["bounds"], truthy(bounds) {
		out.set("bounds", .array(["x", "y", "width", "height"].map { roundLikeJavaScript(bounds[$0]) }))
	}
	if attributes["axEnabledKnown"] == "false" { out.set("enabled", "unknown") }
	else if element["is_enabled"] == .bool(false) { out.set("enabled", false) }
	if element["is_selected"] == .bool(true) { out.set("selected", true) }
	if attributes["isFocused"] == "true" { out.set("focused", true) }
	if attributes["isActionable"] == "true" { out.set("actionable", true) }
	if attributes["isValueSettable"] == "true" { out.set("settable", true) }
	if let kind = attributes["roleDescription"], kind.string != nil, plain(kind) != plain(label), plain(kind) != plain(role) {
		out.set("kind", kind)
	}
	for (name, field) in attributes.pairs ?? [] {
		if repeatedAttributes.contains(name) || name == "roleDescription" || out[name] != nil { continue }
		if field == "" || field == .null { continue }
		if numericAttributes.contains(name), let number = javaScriptNumber(field), number.isFinite {
			out.set(name, .number(number))
		} else {
			out.set(name, field == "true" ? true : field == "false" ? false : field)
		}
	}
	let handled: Set = ["id", "role", "label", "value", "bounds", "is_enabled", "is_selected", "attributes"]
	for (name, field) in element.pairs ?? [] where !handled.contains(name) && out[name] == nil {
		out.set(name, field)
	}
	return out
}

/// JavaScript's `===` between two parsed JSON values: primitives by value, objects and arrays never.
private func strictlyEqual(_ a: JSON?, _ b: JSON?) -> Bool {
	switch (a, b) {
	case (nil, nil): true
	case (.null?, .null?): true
	case let (.bool(x)?, .bool(y)?): x == y
	case let (.number(x)?, .number(y)?): x == y
	case let (.string(x)?, .string(y)?): x == y
	default: false
	}
}

/// JavaScript's `Number(value)` for a parsed JSON value.
private func javaScriptNumber(_ value: JSON?) -> Double? {
	switch value {
	case let .number(n)?: return n
	case let .bool(b)?: return b ? 1 : 0
	case .null?: return 0
	case let .string(s)?:
		let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty { return 0 }
		if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") { return UInt64(trimmed.dropFirst(2), radix: 16).map(Double.init) }
		if trimmed == "Infinity" || trimmed == "+Infinity" { return .infinity }
		if trimmed == "-Infinity" { return -.infinity }
		guard trimmed.allSatisfy({ "0123456789+-.eE".contains($0) }) else { return nil }
		return Double(trimmed)
	default: return nil
	}
}

/// `Math.round(Number(value))`, which rounds halves up; NaN becomes null, as JSON.stringify writes it.
private func roundLikeJavaScript(_ value: JSON?) -> JSON {
	guard let number = javaScriptNumber(value), number.isFinite else { return .null }
	return .number((number + 0.5).rounded(.down))
}

/// Text compared without case, spacing or an AX prefix, so "outline row" matches "AXOutlineRow".
private func plain(_ value: JSON?) -> String {
	let text: String = switch value {
	case nil, .null?: ""
	case let .string(s)?: s
	case let .bool(b)?: b ? "true" : "false"
	case let .number(n)?: n.rounded() == n && abs(n) < 1e21 ? String(Int64(n)) : String(n)
	case .array?: "" // Not met: roles and labels are strings.
	case .object?: "[object Object]"
	}
	var lowered = text.lowercased()
	if lowered.hasPrefix("ax") { lowered.removeFirst(2) }
	return String(lowered.unicodeScalars.filter { ("a"..."z").contains($0) }.map(Character.init))
}

/// A window row lists its target, which already holds its ID, bounds and minimized state, and only what else differs.
private func compactWindow(_ row: JSON) -> JSON {
	var out = JSON.object([])
	out.set("target", row["target"])
	if truthy(row["window_title"]) { out.set("title", row["window_title"]) }
	if truthy(row["availability"]) { out.set("availability", row["availability"]) }
	if row["is_key"] == .bool(true) { out.set("key", true) }
	if row["is_main"] == .bool(true) { out.set("main", true) }
	if let capability = row["observation_capability"], truthy(capability), capability != "combined_eligible" {
		out.set("observation_capability", capability)
	}
	if truthy(row["observation_reason"]) { out.set("observation_reason", row["observation_reason"]) }
	if let spaces = row["space_ids"], spaces.array?.isEmpty == false { out.set("space_ids", spaces) }
	if let index = row["display_index"]?.number, index > 0 { out.set("display_index", row["display_index"]) }
	let known: Set = [
		"target", "window_title", "availability", "is_key", "is_main", "observation_capability", "observation_reason",
		"space_ids", "display_index", "window_id", "is_minimized", "bounds", "process_start_identity_decimal", "pid",
		"display_asleep", "display_current_space_id", "is_on_screen",
	]
	for (name, field) in row.pairs ?? [] where !known.contains(name) { out.set(name, field) }
	return out
}

/// An app row lists its pid for desktop_windows, its target for app tools, and states only where known and set.
private func compactApp(_ row: JSON) -> JSON {
	var out = JSON.object([])
	out.set("name", row["name"])
	if truthy(row["bundle_id"]) { out.set("bundle_id", row["bundle_id"]) }
	out.set("pid", row["pid"])
	out.set("target", row["target"])
	if row["is_active_known"] == .bool(false) { out.set("active", "unknown") }
	else if row["is_active"] == .bool(true) { out.set("active", true) }
	if row["is_hidden_known"] == .bool(false) { out.set("hidden", "unknown") }
	else if row["is_hidden"] == .bool(true) { out.set("hidden", true) }
	let known: Set = [
		"name", "bundle_id", "target", "pid", "process_start_identity_decimal", "is_active", "is_active_known",
		"is_hidden", "is_hidden_known",
	]
	for (name, field) in row.pairs ?? [] where !known.contains(name) { out.set(name, field) }
	return out
}
