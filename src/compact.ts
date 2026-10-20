import type { Json } from "./results.js";

/**
 * The shape results take for a model: what an agent acts on, once.
 *
 * Native results carry detection metadata, timings, receipts the client has already checked, duplicated fields and
 * booleans spelled as strings. A model pays for all of it in every call, so results leave it out unless the client
 * is verbose. Internal reads (waits, cell edits, notifications) keep the full shape; only the final result is made
 * compact.
 */
export type CompactOptions = {
	/** List every window, including the untitled off-screen strips most apps keep, instead of counting them. */
	allWindows?: boolean;
};

/** Native fields that describe how a result was produced, not what it found. */
const INTERNAL = new Set([
	"detection_metadata",
	"diagnostics",
	"timings",
	"coordinate_context",
	"element_count",
	"target_receipt",
	"requires_fresh_observation",
]);

/** Fields of an element's attributes that repeat the element itself. */
const REPEATED_ATTRIBUTES = new Set(["role", "isFocused", "isActionable", "axEnabledKnown", "isValueSettable"]);

/** Attributes whose numbers arrive as strings. */
const NUMERIC_ATTRIBUTES = new Set(["depth", "disclosureLevel"]);

export function compactResult(text: string, options: CompactOptions = {}): string {
	return JSON.stringify(compact(JSON.parse(text), options));
}

export function compact(value: unknown, options: CompactOptions = {}, key?: string): unknown {
	if (Array.isArray(value)) {
		if ((key === "ui_elements" || key === "elements") && value.every(isElement)) return value.map(compactElement);
		if ((key === "windows" || key === "created_windows") && value.every(isWindowRow)) {
			return value.map((row) => compactWindow(row, options));
		}
		if (key === "apps" && value.every(isAppRow)) return value.map(compactApp);
		return value.map((item) => compact(item, options));
	}
	if (!value || typeof value !== "object") return value;
	if (key === "application" && isAppRow(value)) return compactApp(value);
	if (key === "window" && isWindowRow(value)) return compactWindow(value, options);
	const source = value as Json;
	const out: Json = {};
	for (const [name, field] of Object.entries(source)) {
		if (INTERNAL.has(name)) continue;
		if (Array.isArray(field) && !field.length && /warnings$/.test(name)) continue;
		if (name === "inspection_mode" && field === "accessibility") continue;
		if (name === "native_outcome") {
			// An expectation that matched keeps the native "unknown" it overrode.
			if (typeof field === "string") out[name] = field;
			// An unknown outcome is the one case where the agent decides whether repeating is safe.
			const retry = (field as Json | null)?.retry_safety;
			if (source.outcome === "unknown" && typeof retry === "string") out.retry_safety = retry;
			continue;
		}
		// An action echoes its own name and the snapshot it was given.
		if (key === "action" && (name === "action" || name === "snapshot_id")) continue;
		if (key === "image" && name === "note") continue;
		if (key === "system" && name === "note") continue;
		if ((name === "session" || name === "appearance") && field && typeof field === "object") {
			out[name] = withoutFalse(field as Json);
			continue;
		}
		if (name === "windows" && Array.isArray(field) && field.every(isWindowRow) && !options.allWindows) {
			const shown = field.filter((row) => !isStrip(row));
			out[name] = compact(shown, options, name);
			if (shown.length < field.length) out.hidden_windows = field.length - shown.length;
			continue;
		}
		out[name] = compact(field, options, name);
	}
	return out;
}

function isElement(value: unknown): value is Json {
	return !!value && typeof value === "object" && typeof (value as Json).id === "string"
		&& ("role" in (value as Json) || "attributes" in (value as Json));
}

function isWindowRow(value: unknown): value is Json {
	const target = (value as Json | null)?.target as Json | undefined;
	return !!target && typeof target === "object" && typeof target.window_id === "number";
}

function isAppRow(value: unknown): value is Json {
	const target = (value as Json | null)?.target as Json | undefined;
	return !!target && typeof target === "object" && typeof target.pid === "number" && !("window_id" in target);
}

/**
 * An untitled window macOS lists off screen and on no Space, such as an app's menu bar strips or a Finder desktop
 * helper. A window on another Space, minimized or hidden with its app keeps a Space or a reason, and stays listed.
 */
function isStrip(row: Json): boolean {
	const availability = row.availability as Json | undefined;
	const target = row.target as Json;
	return !row.window_title && row.is_on_screen === false && target.is_minimized !== true
		&& (!Array.isArray(row.space_ids) || !row.space_ids.length) && availability?.state !== "available";
}

/**
 * One element, once: its ID, role, label, value when it differs, bounds as [x, y, width, height] in whole points,
 * state only where it isn't the default, and its other attributes alongside, with real booleans and numbers.
 */
function compactElement(element: Json): Json {
	const attributes = (element.attributes ?? {}) as Json;
	// Peekaboo calls roles it doesn't name "other"; the Accessibility role says what they are.
	const role = element.role === undefined || element.role === "other" ? attributes.role ?? element.role : element.role;
	const label = element.label;
	const out: Json = { id: element.id, role };
	// Peekaboo labels an unnamed element with its role description, as "cell" for an AXCell.
	if (typeof label === "string" && label && plain(label) !== plain(role)) out.label = label;
	if (element.value !== undefined && element.value !== "" && element.value !== label) out.value = element.value;
	const bounds = element.bounds as Json | undefined;
	if (bounds) out.bounds = [bounds.x, bounds.y, bounds.width, bounds.height].map((n) => Math.round(Number(n)));
	if (attributes.axEnabledKnown === "false") out.enabled = "unknown";
	else if (element.is_enabled === false) out.enabled = false;
	if (element.is_selected === true) out.selected = true;
	if (attributes.isFocused === "true") out.focused = true;
	if (attributes.isActionable === "true") out.actionable = true;
	if (attributes.isValueSettable === "true") out.settable = true;
	const kind = attributes.roleDescription;
	if (typeof kind === "string" && !repeats(kind, role, label)) out.kind = kind;
	for (const [name, field] of Object.entries(attributes)) {
		if (REPEATED_ATTRIBUTES.has(name) || name === "roleDescription" || name in out) continue;
		if (field === "" || field === null || field === undefined) continue;
		out[name] = NUMERIC_ATTRIBUTES.has(name) && Number.isFinite(Number(field))
			? Number(field)
			: field === "true"
			? true
			: field === "false"
			? false
			: field;
	}
	for (const [name, field] of Object.entries(element)) {
		if (["id", "role", "label", "value", "bounds", "is_enabled", "is_selected", "attributes"].includes(name)) continue;
		if (!(name in out)) out[name] = field;
	}
	return out;
}

/** Whether a role description only restates the role ("scroll bar" for AXScrollBar) or the label. */
function repeats(kind: string, role: unknown, label: unknown): boolean {
	return plain(kind) === plain(label) || plain(kind) === plain(role);
}

/** Text compared without case, spacing or an AX prefix, so "outline row" matches "AXOutlineRow". */
function plain(text: unknown): string {
	return String(text ?? "").toLowerCase().replace(/^ax/, "").replace(/[^a-z]/g, "");
}

/** A window row lists its target, which already holds its ID, bounds and minimized state, and only what else differs. */
function compactWindow(row: Json, _options: CompactOptions): Json {
	const out: Json = { target: row.target };
	if (row.window_title) out.title = row.window_title;
	if (row.availability) out.availability = row.availability;
	if (row.is_key === true) out.key = true;
	if (row.is_main === true) out.main = true;
	if (row.observation_capability && row.observation_capability !== "combined_eligible") {
		out.observation_capability = row.observation_capability;
	}
	if (row.observation_reason) out.observation_reason = row.observation_reason;
	if (Array.isArray(row.space_ids) && row.space_ids.length) out.space_ids = row.space_ids;
	if (typeof row.display_index === "number" && row.display_index > 0) out.display_index = row.display_index;
	const known = new Set([
		"target", "window_title", "availability", "is_key", "is_main", "observation_capability", "observation_reason",
		"space_ids", "display_index", "window_id", "is_minimized", "bounds", "process_start_identity_decimal", "pid",
		"display_asleep", "display_current_space_id", "is_on_screen",
	]);
	for (const [name, field] of Object.entries(row)) if (!known.has(name)) out[name] = field;
	return out;
}

/** An app row lists its pid for desktop_windows, its target for app tools, and states only where known and set. */
function compactApp(row: Json): Json {
	const out: Json = { name: row.name };
	if (row.bundle_id) out.bundle_id = row.bundle_id;
	out.pid = row.pid;
	out.target = row.target;
	if (row.is_active_known === false) out.active = "unknown";
	else if (row.is_active === true) out.active = true;
	if (row.is_hidden_known === false) out.hidden = "unknown";
	else if (row.is_hidden === true) out.hidden = true;
	const known = new Set([
		"name", "bundle_id", "target", "pid", "process_start_identity_decimal", "is_active", "is_active_known",
		"is_hidden", "is_hidden_known",
	]);
	for (const [name, field] of Object.entries(row)) if (!known.has(name)) out[name] = field;
	return out;
}

function withoutFalse(value: Json): Json {
	return Object.fromEntries(Object.entries(value).filter(([, field]) => field !== false));
}
