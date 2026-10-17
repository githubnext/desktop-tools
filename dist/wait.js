import { DESKTOP_WAIT_CONDITIONS, } from "./protocol.js";
export const WAIT_DEFAULT_MS = 10_000;
/** Below the 60-second request timeout common MCP clients use, with room for the final inspection. */
export const WAIT_MAX_MS = 45_000;
const FIRST_DELAY = 200;
const MAX_DELAY = 2_000;
/** The inspection that gives an appeared element a snapshot gets this long after the wait. */
const CONFIRM_MS = 10_000;
const MAX_ROWS = 10;
const MAX_TEXT = 8192;
const APP = ["app_running", "app_frontmost", "app_quit"];
const ELEMENT = ["element_appears", "element_gone"];
const TEXT = ["text_changes", "text_equals", "text_contains"];
function positiveInteger(value, name) {
    if (!Number.isSafeInteger(value) || value < 1)
        throw new Error(`${name} must be a positive integer.`);
}
function exactString(value, name, limit = 512) {
    if (typeof value !== "string" || !value || value.length > limit) {
        throw new Error(`${name} must be a non-empty string of at most ${limit} characters.`);
    }
}
/** Refuses argument combinations a condition doesn't use, so a misplaced filter is never silently ignored. */
export function validateWait(request) {
    const until = request.until;
    if (!DESKTOP_WAIT_CONDITIONS.includes(until)) {
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
            if (!/^[A-Za-z0-9.-]+$/.test(request.bundle_id))
                throw new Error("bundle_id must be an exact bundle ID.");
        }
    }
    else {
        positiveInteger(request.pid, "pid");
        allowed.add("pid");
    }
    if (request.pid !== undefined)
        positiveInteger(request.pid, "pid");
    if (until === "window_appears") {
        if (request.title !== undefined && request.title_contains !== undefined) {
            throw new Error("Supply title or title_contains, not both.");
        }
        if (request.title !== undefined && typeof request.title !== "string")
            throw new Error("title must be a string.");
        if (request.title_contains !== undefined)
            exactString(request.title_contains, "title_contains");
        allowed.add("title").add("title_contains");
    }
    if (until === "window_gone" || until.startsWith("dialog_") || ELEMENT.includes(until) || TEXT.includes(until)) {
        allowed.add("window");
        if (request.window !== undefined || !until.startsWith("dialog_"))
            positiveInteger(request.window, "window");
    }
    if (ELEMENT.includes(until) || TEXT.includes(until)) {
        allowed.add("scope").add("element");
        if (request.scope !== undefined) {
            const scope = request.scope;
            if (!scope || typeof scope !== "object" || Object.keys(scope).some((key) => key !== "snapshot" && key !== "element")) {
                throw new Error("scope takes snapshot and element.");
            }
            exactString(scope.snapshot, "scope.snapshot", 256);
            exactString(scope.element, "scope.element", 256);
        }
        if (ELEMENT.includes(until) && request.element === undefined)
            throw new Error(`${until} needs element.`);
        if (request.element !== undefined)
            validateMatch(request.element, TEXT.includes(until));
    }
    if (until === "text_equals" || until === "text_contains") {
        allowed.add("text");
        if (typeof request.text !== "string" || request.text.length > MAX_TEXT || (until === "text_contains" && !request.text)) {
            throw new Error(`${until} needs text of at most ${MAX_TEXT} characters${until === "text_contains" ? ", not empty" : ""}.`);
        }
    }
    if (request.timeout_ms !== undefined) {
        if (!Number.isSafeInteger(request.timeout_ms) || request.timeout_ms < 100 || request.timeout_ms > WAIT_MAX_MS) {
            throw new Error(`timeout_ms must be an integer from 100 to ${WAIT_MAX_MS}.`);
        }
    }
    const extra = Object.keys(request).filter((key) => !allowed.has(key) && request[key] !== undefined);
    if (extra.length)
        throw new Error(`${until} doesn't use ${extra.join(", ")}.`);
}
function validateMatch(element, forText) {
    const match = element;
    if (!match || typeof match !== "object")
        throw new Error("element must be an object.");
    const keys = forText ? ["role", "title", "identifier"] : ["role", "title", "value", "identifier"];
    if (Object.keys(match).some((key) => !keys.includes(key))) {
        throw new Error(`element takes ${keys.join(", ")}${forText ? "; the text it waits on is the element's value" : ""}.`);
    }
    exactString(match.role, "element.role", 128);
    for (const key of keys.slice(1)) {
        if (match[key] !== undefined && (typeof match[key] !== "string" || match[key].length > MAX_TEXT)) {
            throw new Error(`element.${key} must be a string of at most ${MAX_TEXT} characters.`);
        }
    }
    if (keys.slice(1).every((key) => match[key] === undefined)) {
        throw new Error(`element needs role and at least one of ${keys.slice(1).join(", ")}.`);
    }
}
function parse(result) {
    return JSON.parse(result.text);
}
function message(error) {
    return (error instanceof Error ? error.message : String(error)).slice(0, 2000);
}
/** Apps with the bundle ID or PID, from one complete-or-partial inventory. */
async function findApps(reads, request, signal) {
    const data = parse(await reads.observe({ op: "apps" }, signal));
    const rows = data.apps.filter((app) => request.pid !== undefined ? app.pid === request.pid : app.bundle_id === request.bundle_id);
    return { rows, complete: data.inventory_completeness === "complete" };
}
async function listWindows(reads, pid, signal) {
    const data = parse(await reads.observe({ op: "windows", pid }, signal));
    const rows = data.windows;
    // Accessibility found every window only when no row or warning says its enumeration was cut short.
    const accessible = !rows.some((row) => row.observation_reason === "accessibility_enumeration_incomplete")
        && !(data.inventory_warnings ?? []).some((warning) => /accessibility|timed out/i.test(warning));
    return { rows, complete: data.inventory_completeness === "complete", accessible };
}
/**
 * The window's desktop_windows row, or why it is certainly gone: unlisted in a complete inventory, or its
 * app no longer running. Neither means a partial inventory missed it.
 */
async function findWindow(reads, pid, window, signal) {
    let listed;
    try {
        listed = await listWindows(reads, pid, signal);
    }
    catch (error) {
        signal.throwIfAborted();
        const apps = await findApps(reads, { op: "wait", until: "app_quit", pid }, signal);
        if (apps.complete && !apps.rows.length)
            return { gone: "app_not_running" };
        throw error;
    }
    const row = listed.rows.find((candidate) => candidate.window_id === window);
    if (row)
        return { row, accessible: listed.accessible };
    return listed.complete ? { gone: "window_closed" } : {};
}
function pollApp(reads, request) {
    return async (signal) => {
        const { rows, complete } = await findApps(reads, request, signal);
        const observation = { apps: rows.slice(0, MAX_ROWS), inventory_completeness: complete ? "complete" : "partial" };
        if (request.until === "app_running")
            return { holds: rows.length > 0, observation };
        if (request.until === "app_frontmost") {
            return { holds: rows.some((app) => app.is_active_known === true && app.is_active === true), observation };
        }
        // A partial inventory can omit a running app, so it never proves a quit.
        return { holds: complete && !rows.length, observation };
    };
}
function pollWindowAppears(reads, request) {
    return async (signal) => {
        const pids = request.pid !== undefined
            ? [request.pid]
            : (await findApps(reads, request, signal)).rows.map((app) => app.pid);
        const seen = [];
        const matched = [];
        const errors = [];
        for (const pid of pids) {
            try {
                const { rows } = await listWindows(reads, pid, signal);
                for (const row of rows) {
                    // Off-screen windows on no Space, such as the Finder's menu-bar strips, are never a window appearing.
                    const shown = row.is_on_screen === true || row.is_minimized === true
                        || (Array.isArray(row.space_ids) && row.space_ids.length > 0);
                    if (!shown)
                        continue;
                    const title = String(row.window_title ?? "");
                    const fits = request.title !== undefined
                        ? title === request.title
                        : request.title_contains === undefined || title.includes(request.title_contains);
                    (fits ? matched : seen).push({ pid, ...row });
                }
            }
            catch (error) {
                signal.throwIfAborted();
                errors.push(message(error));
            }
        }
        if (matched.length)
            return { holds: true, observation: { windows: matched.slice(0, MAX_ROWS) } };
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
function pollWindowGone(reads, request) {
    return async (signal) => {
        const pid = request.pid, window = request.window;
        const { row, gone } = await findWindow(reads, pid, window, signal);
        if (gone)
            return { holds: true, observation: { pid, window_id: window, reason: gone } };
        return { holds: false, observation: row ? { pid, ...row } : { pid, window_id: window, inventory_completeness: "partial" } };
    };
}
/** How a dialog read that found no single dialog reads: none found, several found, or anything else, which is unknown. */
function dialogRefusal(text) {
    if (/incomplete/i.test(text))
        return undefined;
    if (/no dialog matched the selected target|no active dialog/i.test(text))
        return "absent";
    if (/dialog target is ambiguous/i.test(text))
        return "several";
    return undefined;
}
function pollDialog(reads, request) {
    const appears = request.until === "dialog_appears";
    return async (signal) => {
        const pid = request.pid;
        let target;
        let accessible;
        if (request.window !== undefined) {
            const { row, gone, accessible: readable } = await findWindow(reads, pid, request.window, signal);
            accessible = readable;
            if (gone) {
                // A sheet goes with its window; a dialog can't appear in a window that is gone.
                return { holds: !appears, observation: { pid, window_id: request.window, reason: gone } };
            }
            target = row?.target;
            if (!target) {
                return {
                    holds: false,
                    observation: { pid, window_id: request.window, error: "The window has no exact target in desktop_windows now." },
                };
            }
        }
        else {
            const { rows, complete } = await findApps(reads, request, signal);
            if (!rows.length) {
                return { holds: !appears && complete, observation: { pid, reason: complete ? "app_not_running" : "app_not_listed" } };
            }
            target = rows[0].target;
            if (!target)
                return { holds: false, observation: { pid, error: "The app has no exact target in desktop_apps now." } };
            accessible = (await listWindows(reads, pid, signal)).accessible;
        }
        try {
            const dialog = parse(await reads.observe({ op: "dialog", target }, signal));
            return { holds: appears, observation: { dialog } };
        }
        catch (error) {
            signal.throwIfAborted();
            const text = message(error);
            const refusal = dialogRefusal(text);
            // The dialog read skips windows Accessibility can't reach, so it proves absence only when all were reached.
            if (refusal === "absent") {
                if (accessible)
                    return { holds: !appears, observation: { pid, dialog: null } };
                return {
                    holds: false,
                    observation: { pid, dialog: null, error: "Accessibility could not reach every window of the app, so no dialog found doesn't prove none is open." },
                };
            }
            // Several open dialogs are present, though desktop_dialog needs a window to read one.
            if (refusal === "several")
                return { holds: appears, observation: { pid, dialogs: "several", error: text } };
            return { holds: false, observation: { pid, error: text } };
        }
    };
}
function elementsInput(request, read) {
    return {
        pid: request.pid,
        window: request.window,
        ...(request.scope ? { scope: request.scope } : {}),
        ...read,
    };
}
function pollElement(reads, request) {
    const appears = request.until === "element_appears";
    return async (signal) => {
        let found;
        try {
            found = await reads.elements(elementsInput(request, { match: request.element }), signal);
        }
        catch (error) {
            signal.throwIfAborted();
            if (!appears) {
                const { gone } = await findWindow(reads, request.pid, request.window, signal);
                if (gone)
                    return { holds: true, observation: { pid: request.pid, window_id: request.window, reason: gone } };
            }
            return { holds: false, observation: { error: message(error) } };
        }
        const count = found.match_count;
        // A cut-short traversal may have missed the element, so it never proves absence.
        return { holds: appears ? count > 0 : count === 0 && found.truncated === false, observation: found };
    };
}
/** The text a text condition compares: the window's or scope's text as desktop_read reads it, or the one matching element's value. */
async function readText(reads, request, signal) {
    if (request.element) {
        const found = await reads.elements(elementsInput(request, { match: request.element }), signal);
        const count = found.match_count;
        if (count > 1)
            return { observation: { ...found, error: "Several elements match; add title or identifier, or a scope." } };
        if (count === 0)
            return { text: null, observation: found };
        const element = found.matches[0];
        const text = (element.value ?? element.label ?? null);
        return { text, observation: { element, text } };
    }
    const { text, truncated, truncation, window_title } = await reads.elements(elementsInput(request, { text: true }), signal);
    return { text: text, observation: { window_title, text, truncated, truncation } };
}
function pollText(reads, request) {
    let baseline;
    return async (signal) => {
        let read;
        try {
            read = await readText(reads, request, signal);
        }
        catch (error) {
            signal.throwIfAborted();
            return { holds: false, observation: { error: message(error) } };
        }
        if (read.text === undefined)
            return { holds: false, observation: read.observation };
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
        if (text === null)
            return { holds: false, observation: read.observation };
        const holds = request.until === "text_equals" ? text === request.text : text.includes(request.text);
        return { holds, observation: read.observation };
    };
}
function checker(reads, request) {
    const until = request.until;
    if (APP.includes(until))
        return pollApp(reads, request);
    if (until === "window_appears")
        return pollWindowAppears(reads, request);
    if (until === "window_gone")
        return pollWindowGone(reads, request);
    if (until.startsWith("dialog_"))
        return pollDialog(reads, request);
    if (ELEMENT.includes(until))
        return pollElement(reads, request);
    return pollText(reads, request);
}
/** Resolves true after the delay, or false when the signal ends the wait first. */
function sleep(ms, signal) {
    if (signal.aborted)
        return Promise.resolve(false);
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
function matchesElement(element, match) {
    const attributes = (element.attributes ?? {});
    return (element.role === match.role || attributes.role === match.role)
        && (match.title === undefined || element.label === match.title || attributes.title === match.title)
        && (match.value === undefined || element.value === match.value)
        && (match.identifier === undefined || attributes.identifier === match.identifier);
}
/** Inspects once after an element appears, so the result carries a snapshot that action tools accept. */
async function confirm(reads, request, abort) {
    const signal = AbortSignal.any([
        ...(abort ? [abort] : []),
        AbortSignal.timeout(CONFIRM_MS),
    ]);
    try {
        const result = await reads.observe({
            op: "inspect",
            pid: request.pid,
            window: request.window,
            ...(request.scope ? { scope: request.scope } : {}),
        }, signal);
        const data = parse(result);
        if (result.isError)
            return { inspection: { snapshot_id: null, error: data.inspection_error } };
        const elements = (data.ui_elements ?? []).filter((element) => matchesElement(element, request.element));
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
    }
    catch (error) {
        abort?.throwIfAborted();
        return { inspection: { snapshot_id: null, error: message(error) } };
    }
}
/** Polls one read-only condition with backoff until it holds or the timeout passes. Sends no input. */
export async function waitFor(reads, request, abort) {
    validateWait(request);
    const timeout = request.timeout_ms ?? WAIT_DEFAULT_MS;
    const started = Date.now();
    const deadline = AbortSignal.timeout(timeout);
    const signal = abort ? AbortSignal.any([abort, deadline]) : deadline;
    const check = checker(reads, request);
    let last;
    let lastError;
    let polls = 0;
    for (let delay = FIRST_DELAY;; delay = Math.min(Math.round(delay * 1.5), MAX_DELAY)) {
        try {
            last = await check(signal);
            polls++;
            lastError = undefined;
        }
        catch (error) {
            abort?.throwIfAborted();
            if (deadline.aborted)
                break;
            // A failed read is one more observation; the condition is read again next time.
            polls++;
            lastError = message(error);
        }
        if (last?.holds)
            break;
        if (!(await sleep(delay, signal))) {
            abort?.throwIfAborted();
            break;
        }
    }
    const matched = last?.holds === true;
    const result = {
        until: request.until,
        status: matched ? "matched" : "timed_out",
        elapsed_ms: Date.now() - started,
        polls,
    };
    let image;
    if (matched) {
        result.match = last.observation;
        if (request.until === "element_appears") {
            const confirmed = await confirm(reads, request, abort);
            result.inspection = confirmed.inspection;
            image = confirmed.image;
        }
    }
    else {
        result.last_observation = last?.observation ?? null;
        if (lastError)
            result.last_error = lastError;
    }
    result.note = note(request, matched);
    return { text: JSON.stringify(result), ...(image ? { image } : {}) };
}
function note(request, matched) {
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
