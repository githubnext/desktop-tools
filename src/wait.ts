import {
	DESKTOP_WAIT_CONDITIONS,
	type DesktopAppTarget,
	type DesktopElementMatch,
	type DesktopOutcome,
	type DesktopRequest,
	type DesktopResult,
	type DesktopWait,
} from "./protocol.js";
import { errorMessage, type Json, parseResult } from "./results.js";

/** The reads a wait polls; each call is one native process, so nothing is held between polls. */
export type WaitReads = {
	/** One ordinary read request, such as apps, windows, dialog, read or inspect. */
	observe(request: DesktopRequest, signal: AbortSignal): Promise<DesktopResult>;
	/** The native elements read: matching elements or text of one window, through Accessibility alone. */
	elements(input: Record<string, unknown>, signal: AbortSignal): Promise<Record<string, unknown>>;
};

export const WAIT_DEFAULT_MS = 10_000;
/** Below the 60-second request timeout common MCP clients use, with room for the final inspection. */
export const WAIT_MAX_MS = 45_000;
/** An action's expect polls briefly by default; input that took effect usually shows within a few seconds. */
export const EXPECT_DEFAULT_MS = 3_000;
export const EXPECT_MAX_MS = 10_000;
/** An action result with its expectation stays under the client's result limit. */
const MAX_RESULT = 32_000;
const FIRST_DELAY = 200;
const MAX_DELAY = 2_000;
/** The inspection that gives an appeared element a snapshot gets this long after the wait. */
const CONFIRM_MS = 10_000;
const MAX_ROWS = 10;
const MAX_TEXT = 8192;

/** One poll's verdict and what it saw, in the read tools' shapes. */
type Check = { holds: boolean; observation: Json };

const APP = ["app_running", "app_frontmost", "app_quit"];
const ELEMENT = ["element_appears", "element_gone"];
const TEXT = ["text_changes", "text_equals", "text_contains"];

function positiveInteger(value: unknown, name: string) {
	if (!Number.isSafeInteger(value) || (value as number) < 1) throw new Error(`${name} must be a positive integer.`);
}

function exactString(value: unknown, name: string, limit = 512) {
	if (typeof value !== "string" || !value || value.length > limit) {
		throw new Error(`${name} must be a non-empty string of at most ${limit} characters.`);
	}
}

/** Refuses argument combinations a condition doesn't use, so a misplaced filter is never silently ignored. */
function validateWait(request: DesktopWait, maxTimeout = WAIT_MAX_MS) {
	const until = request.until;
	if (!(DESKTOP_WAIT_CONDITIONS as readonly string[]).includes(until)) {
		throw new Error(`Choose until from ${DESKTOP_WAIT_CONDITIONS.join(", ")}.`);
	}
	const allowed = new Set(["op", "until", "timeout_ms"]);
	const app = until === "window_appears" || APP.includes(until);
	if (app) {
		if ((request.bundle_id === undefined) === (request.pid === undefined)) {
			throw new Error(`${until} takes exactly one of bundle_id or pid.`);
		}
		allowed.add("bundle_id").add("pid");
		if (request.bundle_id !== undefined) {
			exactString(request.bundle_id, "bundle_id", 256);
			if (!/^[A-Za-z0-9.-]+$/.test(request.bundle_id)) throw new Error("bundle_id must be an exact bundle ID.");
		}
	} else {
		positiveInteger(request.pid, "pid");
		allowed.add("pid");
	}
	if (request.pid !== undefined) positiveInteger(request.pid, "pid");
	if (until === "window_appears") {
		if (request.title !== undefined && request.title_contains !== undefined) {
			throw new Error("Supply title or title_contains, not both.");
		}
		if (request.title !== undefined && typeof request.title !== "string") throw new Error("title must be a string.");
		if (request.title_contains !== undefined) exactString(request.title_contains, "title_contains");
		allowed.add("title").add("title_contains");
	}
	if (until === "window_gone" || until.startsWith("dialog_") || ELEMENT.includes(until) || TEXT.includes(until)) {
		allowed.add("window");
		if (request.window !== undefined || !until.startsWith("dialog_")) positiveInteger(request.window, "window");
	}
	if (ELEMENT.includes(until) || TEXT.includes(until)) {
		allowed.add("scope").add("element");
		if (request.scope !== undefined) {
			const scope = request.scope as unknown as Json;
			if (!scope || typeof scope !== "object" || Object.keys(scope).some((key) => key !== "snapshot" && key !== "element")) {
				throw new Error("scope takes snapshot and element.");
			}
			exactString(scope.snapshot, "scope.snapshot", 256);
			exactString(scope.element, "scope.element", 256);
		}
		if (ELEMENT.includes(until) && request.element === undefined) throw new Error(`${until} needs element.`);
		if (request.element !== undefined) validateMatch(request.element, TEXT.includes(until));
	}
	if (ELEMENT.includes(until) || TEXT.includes(until)) {
		allowed.add("web_accessibility");
		if (request.web_accessibility !== undefined && typeof request.web_accessibility !== "boolean") {
			throw new Error("Choose web_accessibility true or false.");
		}
	}
	if (until === "text_equals" || until === "text_contains") {
		allowed.add("text");
		if (typeof request.text !== "string" || request.text.length > MAX_TEXT || (until === "text_contains" && !request.text)) {
			throw new Error(`${until} needs text of at most ${MAX_TEXT} characters${until === "text_contains" ? ", not empty" : ""}.`);
		}
	}
	if (request.timeout_ms !== undefined) {
		if (!Number.isSafeInteger(request.timeout_ms) || request.timeout_ms < 100 || request.timeout_ms > maxTimeout) {
			throw new Error(`timeout_ms must be an integer from 100 to ${maxTimeout}.`);
		}
	}
	const extra = Object.keys(request).filter((key) => !allowed.has(key) && (request as Json)[key] !== undefined);
	if (extra.length) throw new Error(`${until} doesn't use ${extra.join(", ")}.`);
}

function validateMatch(element: DesktopElementMatch, forText: boolean) {
	const match = element as unknown as Json;
	if (!match || typeof match !== "object") throw new Error("element must be an object.");
	const keys = forText ? ["role", "title", "identifier"] : ["role", "title", "value", "identifier"];
	if (Object.keys(match).some((key) => !keys.includes(key))) {
		throw new Error(`element takes ${keys.join(", ")}${forText ? "; the text it waits on is the element's value" : ""}.`);
	}
	exactString(match.role, "element.role", 128);
	for (const key of keys.slice(1)) {
		if (match[key] !== undefined && (typeof match[key] !== "string" || (match[key] as string).length > MAX_TEXT)) {
			throw new Error(`element.${key} must be a string of at most ${MAX_TEXT} characters.`);
		}
	}
	if (keys.slice(1).every((key) => match[key] === undefined)) {
		throw new Error(`element needs role and at least one of ${keys.slice(1).join(", ")}.`);
	}
}


/** Apps with the bundle ID or PID, from one complete-or-partial inventory. */
async function findApps(reads: WaitReads, request: DesktopWait, signal: AbortSignal) {
	// With many apps running, the whole list is cut to fit a result, so a bundle ID is matched natively first.
	const query = request.pid === undefined ? request.bundle_id : undefined;
	const data = parseResult(await reads.observe({ op: "apps", ...(query === undefined ? {} : { query }) }, signal));
	const rows = (data.apps as Json[]).filter((app) =>
		request.pid !== undefined ? app.pid === request.pid : app.bundle_id === request.bundle_id
	);
	// A cut list may have dropped the app, so it never proves the app is gone.
	return { rows, complete: data.inventory_completeness === "complete" && data.truncated !== true };
}

async function listWindows(reads: WaitReads, pid: number, signal: AbortSignal) {
	const data = parseResult(await reads.observe({ op: "windows", pid }, signal));
	const rows = data.windows as Json[];
	// Accessibility found every window only when no row or warning says its enumeration was cut short.
	const accessible = !rows.some((row) => row.observation_reason === "accessibility_enumeration_incomplete")
		&& !((data.inventory_warnings ?? []) as string[]).some((warning) => /accessibility|timed out/i.test(warning));
	return { rows, complete: data.inventory_completeness === "complete", accessible, hidden: data.app_hidden === true };
}

/**
 * Whether a window counts as open. Off-screen windows on no Space, such as the Finder's menu-bar strips, never
 * do. Neither does one off screen on its display's current Space while its app isn't hidden, such as the
 * ordered-out Spotlight panel that macOS 27 keeps listed.
 */
function windowShown(row: Json, appHidden: boolean) {
	if (row.is_on_screen === true || row.is_minimized === true) return true;
	const spaces = Array.isArray(row.space_ids) ? row.space_ids as number[] : [];
	if (!spaces.length) return false;
	const current = row.display_current_space_id;
	if (typeof current !== "number" || appHidden || row.display_asleep === true) return true;
	return !spaces.includes(current);
}

/**
 * The window's desktop_windows row, or why it is certainly gone: unlisted in a complete inventory, or its
 * app no longer running. Neither means a partial inventory missed it.
 */
async function findWindow(reads: WaitReads, pid: number, window: number, signal: AbortSignal) {
	let listed: Awaited<ReturnType<typeof listWindows>>;
	try {
		listed = await listWindows(reads, pid, signal);
	} catch (error) {
		signal.throwIfAborted();
		const apps = await findApps(reads, { op: "wait", until: "app_quit", pid }, signal);
		if (apps.complete && !apps.rows.length) return { gone: "app_not_running" };
		throw error;
	}
	const row = listed.rows.find((candidate) => candidate.window_id === window);
	if (row) return { row, accessible: listed.accessible };
	return listed.complete ? { gone: "window_closed" } : {};
}

function pollApp(reads: WaitReads, request: DesktopWait) {
	return async (signal: AbortSignal): Promise<Check> => {
		const { rows, complete } = await findApps(reads, request, signal);
		const observation = { apps: rows.slice(0, MAX_ROWS), inventory_completeness: complete ? "complete" : "partial" };
		if (request.until === "app_running") return { holds: rows.length > 0, observation };
		if (request.until === "app_frontmost") {
			return { holds: rows.some((app) => app.is_active_known === true && app.is_active === true), observation };
		}
		// A partial inventory can omit a running app, so it never proves a quit.
		return { holds: complete && !rows.length, observation };
	};
}

function pollWindowAppears(reads: WaitReads, request: DesktopWait) {
	return async (signal: AbortSignal): Promise<Check> => {
		const pids = request.pid !== undefined
			? [request.pid]
			: (await findApps(reads, request, signal)).rows.map((app) => app.pid as number);
		const seen: Json[] = [];
		const matched: Json[] = [];
		const errors: string[] = [];
		for (const pid of pids) {
			try {
				const { rows, hidden } = await listWindows(reads, pid, signal);
				for (const row of rows) {
					if (!windowShown(row, hidden)) continue;
					const title = String(row.window_title ?? "");
					const fits = request.title !== undefined
						? title === request.title
						: request.title_contains === undefined || title.includes(request.title_contains);
					(fits ? matched : seen).push({ pid, ...row });
				}
			} catch (error) {
				signal.throwIfAborted();
				errors.push(errorMessage(error));
			}
		}
		if (matched.length) return { holds: true, observation: { windows: matched.slice(0, MAX_ROWS) } };
		return {
			holds: false,
			observation: {
				running_pids: pids,
				windows: seen.slice(0, MAX_ROWS),
				...(errors.length ? { errors } : {}),
			},
		};
	};
}

function pollWindowGone(reads: WaitReads, request: DesktopWait) {
	return async (signal: AbortSignal): Promise<Check> => {
		const pid = request.pid!, window = request.window!;
		const { row, gone } = await findWindow(reads, pid, window, signal);
		if (gone) return { holds: true, observation: { pid, window_id: window, reason: gone } };
		return { holds: false, observation: row ? { pid, ...row } : { pid, window_id: window, inventory_completeness: "partial" } };
	};
}

/** How a dialog read that found no single dialog reads: none found, several found, or anything else, which is unknown. */
function dialogRefusal(text: string): "absent" | "several" | undefined {
	if (/incomplete/i.test(text)) return undefined;
	if (/no dialog matched the selected target|no active dialog/i.test(text)) return "absent";
	if (/dialog target is ambiguous/i.test(text)) return "several";
	return undefined;
}

function pollDialog(reads: WaitReads, request: DesktopWait) {
	const appears = request.until === "dialog_appears";
	return async (signal: AbortSignal): Promise<Check> => {
		const pid = request.pid!;
		let target: DesktopAppTarget | undefined;
		let accessible: boolean | undefined;
		if (request.window !== undefined) {
			const { row, gone, accessible: readable } = await findWindow(reads, pid, request.window, signal);
			accessible = readable;
			if (gone) {
				// A sheet goes with its window; a dialog can't appear in a window that is gone.
				return { holds: !appears, observation: { pid, window_id: request.window, reason: gone } };
			}
			target = row?.target as DesktopAppTarget | undefined;
			if (!target) {
				return {
					holds: false,
					observation: { pid, window_id: request.window, error: "The window has no exact target in desktop_windows now." },
				};
			}
		} else {
			const { rows, complete } = await findApps(reads, request, signal);
			if (!rows.length) {
				return { holds: !appears && complete, observation: { pid, reason: complete ? "app_not_running" : "app_not_listed" } };
			}
			target = rows[0].target as DesktopAppTarget | undefined;
			if (!target) return { holds: false, observation: { pid, error: "The app has no exact target in desktop_apps now." } };
			accessible = (await listWindows(reads, pid, signal)).accessible;
		}
		try {
			const dialog = parseResult(await reads.observe({ op: "dialog", target }, signal));
			return { holds: appears, observation: { dialog } };
		} catch (error) {
			signal.throwIfAborted();
			const text = errorMessage(error);
			const refusal = dialogRefusal(text);
			// The dialog read skips windows Accessibility can't reach, so it proves absence only when all were reached.
			if (refusal === "absent") {
				if (accessible) return { holds: !appears, observation: { pid, dialog: null } };
				return {
					holds: false,
					observation: { pid, dialog: null, error: "Accessibility could not reach every window of the app, so no dialog found doesn't prove none is open." },
				};
			}
			// Several open dialogs are present, though desktop_dialog needs a window to read one.
			if (refusal === "several") return { holds: appears, observation: { pid, dialogs: "several", error: text } };
			return { holds: false, observation: { pid, error: text } };
		}
	};
}

function elementsInput(request: DesktopWait, read: { match: DesktopElementMatch } | { text: true }): Json {
	return {
		pid: request.pid,
		window: request.window,
		...(request.scope ? { scope: request.scope } : {}),
		...(request.web_accessibility === false ? { web_accessibility: false } : {}),
		...read,
	};
}

function pollElement(reads: WaitReads, request: DesktopWait) {
	const appears = request.until === "element_appears";
	return async (signal: AbortSignal): Promise<Check> => {
		let found: Json;
		try {
			found = await reads.elements(elementsInput(request, { match: request.element! }), signal);
		} catch (error) {
			signal.throwIfAborted();
			if (!appears) {
				const { gone } = await findWindow(reads, request.pid!, request.window!, signal);
				if (gone) return { holds: true, observation: { pid: request.pid, window_id: request.window, reason: gone } };
			}
			return { holds: false, observation: { error: errorMessage(error) } };
		}
		const count = found.match_count as number;
		// A cut-short traversal may have missed the element, so it never proves absence.
		return { holds: appears ? count > 0 : count === 0 && found.truncated === false, observation: found };
	};
}

/** The text a text condition compares: the window's or scope's text as desktop_read reads it, or the one matching element's value. */
async function readText(reads: WaitReads, request: DesktopWait, signal: AbortSignal) {
	if (request.element) {
		const found = await reads.elements(elementsInput(request, { match: request.element }), signal);
		const count = found.match_count as number;
		if (count > 1) return { observation: { ...found, error: "Several elements match; add title or identifier, or a scope." } };
		if (count === 0) return { text: null, observation: found };
		const element = (found.matches as Json[])[0];
		const text = (element.value ?? element.label ?? null) as string | null;
		return { text, observation: { element, text } };
	}
	const { text, truncated, truncation, window_title, web_accessibility, web_accessibility_via } = await reads.elements(
		elementsInput(request, { text: true }),
		signal,
	);
	return {
		text: text as string,
		observation: { window_title, text, truncated, truncation, web_accessibility, web_accessibility_via },
	};
}

function pollText(reads: WaitReads, request: DesktopWait) {
	let baseline: { text: string | null } | undefined;
	return async (signal: AbortSignal): Promise<Check> => {
		let read: { text?: string | null; observation: Json };
		try {
			read = await readText(reads, request, signal);
		} catch (error) {
			signal.throwIfAborted();
			return { holds: false, observation: { error: errorMessage(error) } };
		}
		if (read.text === undefined) return { holds: false, observation: read.observation };
		const text = read.text;
		if (request.until === "text_changes") {
			// The first successful read is the baseline; an element that appears or disappears also changes it.
			if (!baseline) {
				baseline = { text };
				return { holds: false, observation: { ...read.observation, baseline: true } };
			}
			return {
				holds: text !== baseline.text,
				observation: { ...read.observation, before: baseline.text },
			};
		}
		if (text === null) return { holds: false, observation: read.observation };
		const holds = request.until === "text_equals" ? text === request.text : text.includes(request.text!);
		return { holds, observation: read.observation };
	};
}

function checker(reads: WaitReads, request: DesktopWait) {
	const until = request.until;
	if (APP.includes(until)) return pollApp(reads, request);
	if (until === "window_appears") return pollWindowAppears(reads, request);
	if (until === "window_gone") return pollWindowGone(reads, request);
	if (until.startsWith("dialog_")) return pollDialog(reads, request);
	if (ELEMENT.includes(until)) return rememberTurnOn(pollElement(reads, request));
	return rememberTurnOn(pollText(reads, request));
}

/** Keeps reporting that this wait turned web accessibility on after a later poll finds it already on. */
function rememberTurnOn(poll: (signal: AbortSignal) => Promise<Check>) {
	let turnedOn: Json | undefined;
	return async (signal: AbortSignal): Promise<Check> => {
		const check = await poll(signal);
		const observation = check.observation as Json | undefined;
		if (observation?.web_accessibility === "enabled") {
			turnedOn = { web_accessibility: "enabled", web_accessibility_via: observation.web_accessibility_via };
		} else if (turnedOn && observation?.web_accessibility === "already_on") {
			return { ...check, observation: { ...observation, ...turnedOn } };
		}
		return check;
	};
}

/** Resolves true after the delay, or false when the signal ends the wait first. */
function sleep(ms: number, signal: AbortSignal): Promise<boolean> {
	if (signal.aborted) return Promise.resolve(false);
	return new Promise((resolve) => {
		const timer = setTimeout(() => {
			signal.removeEventListener("abort", stop);
			resolve(true);
		}, ms);
		const stop = () => {
			clearTimeout(timer);
			resolve(false);
		};
		signal.addEventListener("abort", stop, { once: true });
	});
}

function matchesElement(element: Json, match: DesktopElementMatch) {
	const attributes = (element.attributes ?? {}) as Json;
	return (element.role === match.role || attributes.role === match.role)
		&& (match.title === undefined || element.label === match.title || attributes.title === match.title)
		&& (match.value === undefined || element.value === match.value)
		&& (match.identifier === undefined || attributes.identifier === match.identifier);
}

/** Inspects once after an element appears, so the result carries a snapshot that action tools accept. */
async function confirm(reads: WaitReads, request: DesktopWait, abort?: AbortSignal) {
	const signal = AbortSignal.any([
		...(abort ? [abort] : []),
		AbortSignal.timeout(CONFIRM_MS),
	]);
	try {
		const result = await reads.observe({
			op: "inspect",
			pid: request.pid!,
			window: request.window!,
			...(request.scope ? { scope: request.scope } : {}),
			...(request.web_accessibility === false ? { web_accessibility: false } : {}),
		}, signal);
		const data = parseResult(result);
		if (result.isError) return { inspection: { snapshot_id: null, error: data.inspection_error } };
		const elements = ((data.ui_elements ?? []) as Json[]).filter((element) => matchesElement(element, request.element!));
		const inspection = {
			snapshot_id: elements.length ? data.snapshot_id : null,
			window_title: data.window_title,
			elements: elements.slice(0, MAX_ROWS),
			...(elements.length ? {} : {
				note: request.scope
					? "The element is no longer in this inspection; it may have changed again. Wait or inspect again."
					: "The element is not among this inspection's elements, which stop at its first 200. Inspect again with a scope that contains it to act on it.",
			}),
		};
		return { inspection, image: elements.length ? result.image : undefined };
	} catch (error) {
		abort?.throwIfAborted();
		return { inspection: { snapshot_id: null, error: errorMessage(error) } };
	}
}

/** Polls a condition with backoff until it holds or the timeout passes. Sends no input. */
async function poll(check: (signal: AbortSignal) => Promise<Check>, timeout: number, abort?: AbortSignal) {
	const started = Date.now();
	const deadline = AbortSignal.timeout(timeout);
	const signal = abort ? AbortSignal.any([abort, deadline]) : deadline;
	let last: Check | undefined;
	let lastError: string | undefined;
	let polls = 0;
	for (let delay = FIRST_DELAY;; delay = Math.min(Math.round(delay * 1.5), MAX_DELAY)) {
		try {
			last = await check(signal);
			polls++;
			lastError = undefined;
		} catch (error) {
			abort?.throwIfAborted();
			if (deadline.aborted) break;
			// A failed read is one more observation; the condition is read again next time.
			polls++;
			lastError = errorMessage(error);
		}
		if (last?.holds) break;
		if (!(await sleep(delay, signal))) {
			abort?.throwIfAborted();
			break;
		}
	}
	return { last, lastError, polls, elapsed: Date.now() - started };
}

/** What a poll ended with, in desktop_wait's result shape; an appeared element also gets a snapshot. */
async function report(reads: WaitReads, request: DesktopWait, polled: Awaited<ReturnType<typeof poll>>, abort?: AbortSignal) {
	const { last, lastError, polls, elapsed } = polled;
	const matched = last?.holds === true;
	const result: Json = {
		until: request.until,
		status: matched ? "matched" : "timed_out",
		elapsed_ms: elapsed,
		polls,
	};
	let image: DesktopResult["image"];
	if (matched) {
		result.match = last!.observation;
		if (request.until === "element_appears") {
			const confirmed = await confirm(reads, request, abort);
			result.inspection = confirmed.inspection;
			image = confirmed.image;
		}
	} else {
		result.last_observation = last?.observation ?? null;
		if (lastError) result.last_error = lastError;
	}
	return { matched, result, image };
}

/** Polls one read-only condition with backoff until it holds or the timeout passes. Sends no input. */
export async function waitFor(reads: WaitReads, request: DesktopWait, abort?: AbortSignal): Promise<DesktopResult> {
	validateWait(request);
	const polled = await poll(checker(reads, request), request.timeout_ms ?? WAIT_DEFAULT_MS, abort);
	const { matched, result, image } = await report(reads, request, polled, abort);
	result.note = note(request, matched);
	return { text: JSON.stringify(result), ...(image ? { image } : {}) };
}

/** The condition an action's expect names: desktop_wait's arguments without op, with a shorter timeout. */
export function validateExpect(expect: unknown): DesktopWait {
	if (!expect || typeof expect !== "object" || Array.isArray(expect)) {
		throw new Error("expect must be an object naming a desktop_wait condition with until.");
	}
	if ("op" in expect) throw new Error("expect takes desktop_wait's arguments without op.");
	const request = { op: "wait", ...expect } as DesktopWait;
	validateWait(request, EXPECT_MAX_MS);
	return request;
}

/** Input the expectation follows: one action call, which runs at most once. */
type ExpectedAction = (signal?: AbortSignal) => Promise<DesktopResult>;

/**
 * Runs an action once, and when its outcome is unknown, polls the expected condition for a short time.
 * The condition is read before input and must not already hold, so a later match shows the input's effect;
 * the outcome becomes completed only on that match. Input is never repeated.
 */
export async function expectAfter(
	reads: WaitReads,
	expect: DesktopWait,
	act: ExpectedAction,
	abort?: AbortSignal,
): Promise<DesktopResult> {
	const check = checker(reads, expect);
	let before: Check;
	try {
		before = await check(AbortSignal.any([...(abort ? [abort] : []), AbortSignal.timeout(CONFIRM_MS)]));
	} catch (error) {
		abort?.throwIfAborted();
		return refusedExpect(expect, `The expected condition couldn't be read before input: ${errorMessage(error)}`, null);
	}
	if (before.holds) {
		return refusedExpect(
			expect,
			"The expected condition already holds, so it can't show what this action does. Expect a condition the action changes, or leave out expect.",
			before.observation,
		);
	}
	if (before.observation.error !== undefined) {
		return refusedExpect(
			expect,
			"The expected condition couldn't be read reliably before input, so a later match wouldn't show this action's effect. Fix the condition, or leave out expect.",
			before.observation,
		);
	}
	const result = await act(abort);
	if (result.outcome !== "unknown") return result;
	const data = parseResult(result);
	const action = (data.action ?? {}) as Json;
	let polled: Awaited<ReturnType<typeof poll>>;
	try {
		polled = await poll(check, expect.timeout_ms ?? EXPECT_DEFAULT_MS, abort);
	} catch {
		// Stopping ends the check, not the input already sent; the outcome stays unknown.
		return expectResult(data, { until: expect.until, status: "interrupted" }, "unknown");
	}
	const { matched, result: expectation, image } = await report(reads, expect, polled).catch((error) => ({
		matched: false,
		result: { until: expect.until, status: "timed_out", last_error: errorMessage(error) } as Json,
		image: undefined,
	}));
	if (!matched) {
		expectation.note = "The condition did not hold before the timeout, so the outcome stays unknown. The input was not repeated; observe before acting again.";
		return expectResult(data, expectation, "unknown");
	}
	expectation.note = "The condition did not hold before input and held after it, so the outcome is completed. It may change afterward; inspect before acting.";
	return expectResult({ ...data, action: { ...action, outcome: "completed", native_outcome: "unknown" } }, expectation, "completed", image);
}

function refusedExpect(expect: DesktopWait, reason: string, observation: Json | null): DesktopResult {
	const text = JSON.stringify({
		action: { outcome: "refused", reason, message: "No input was sent." },
		expectation: { until: expect.until, status: "refused", before: observation },
	});
	return { text: Buffer.byteLength(text) > MAX_RESULT ? JSON.stringify({ action: { outcome: "refused", reason, message: "No input was sent." } }) : text, outcome: "refused", isError: true };
}

/** Bounds an expectation that would make the action result too long, keeping its status and the action. */
function expectResult(data: Json, expectation: Json, outcome: DesktopOutcome, image?: DesktopResult["image"]): DesktopResult {
	let text = JSON.stringify({ ...data, expectation });
	if (Buffer.byteLength(text) > MAX_RESULT) {
		const { match: _match, last_observation: _last, inspection, ...rest } = expectation;
		const kept = inspection ? { ...rest, inspection: { snapshot_id: (inspection as Json).snapshot_id } } : rest;
		text = JSON.stringify({ ...data, expectation: { ...kept, omitted: "The observation exceeded the result limit; inspect to see it." } });
	}
	return { text, outcome, isError: outcome !== "completed", ...(image ? { image } : {}) };
}

function note(request: DesktopWait, matched: boolean) {
	if (!matched) {
		return "The condition did not hold before the timeout. Nothing was sent; observe again before acting, or wait again.";
	}
	if (request.until === "element_appears") {
		return "inspection.snapshot_id and the listed element IDs come from one inspection taken after the match and work with click and the other action tools. When it is null, inspect before acting.";
	}
	if (request.until === "window_appears") {
		return "Each window's target and window_id work as desktop_windows rows do; pass pid and window_id to desktop_inspect before input.";
	}
	return "The condition held at the last poll and may change afterward; inspect before acting.";
}
