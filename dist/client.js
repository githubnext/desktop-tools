import { execFile } from "node:child_process";
import { constants, existsSync } from "node:fs";
import { lstat, mkdtemp, open, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { DESKTOP_BUTTONS, DESKTOP_CLICKS, DESKTOP_DIRECTIONS, DESKTOP_ELEMENT_ACTIONS, DESKTOP_MODIFIERS, DESKTOP_SELECTIONS, isDesktopAction, isDesktopKey, isDesktopManagement, } from "./protocol.js";
const exec = promisify(execFile);
const MAX_TEXT = 32_000;
/** A scoped inspection lists more elements; recognized text has its own native line and byte limits. */
const MAX_SCOPED_TEXT = 64_000;
const MAX_RECOGNIZED_TEXT = 64_000;
const MAX_READ_TEXT = 128_000;
const MAX_IMAGE = 900_000;
const MAX_OUTPUT = 2_000_000;
const MAX_CLIPBOARD_IMAGE = 10 * 1024 * 1024;
class NativeError extends Error {
    code;
    constructor(code, message) {
        super(message);
        this.code = code;
    }
}
async function run(path, args, signal, errorJson = false, input, agent) {
    signal.throwIfAborted();
    try {
        const pending = exec(path, args, {
            encoding: "utf8",
            // The host reads this from the client while a request is pending, to label the window in use.
            env: agent ? { ...process.env, DESKTOP_TOOLS_AGENT: agent } : process.env,
            signal,
            killSignal: "SIGKILL",
            maxBuffer: MAX_OUTPUT,
        });
        let inputError;
        if (input !== undefined) {
            // A signing or setup refusal can exit before reading stdin; its JSON still owns the outcome.
            pending.child.stdin.on("error", (error) => inputError = error);
            pending.child.stdin.end(input);
        }
        const { stdout } = await pending;
        if (inputError && !stdout.trim())
            throw inputError;
        return stdout;
    }
    catch (error) {
        signal.throwIfAborted();
        const failed = error;
        // The native client reports expected refusals as JSON on unsuccessful exits too.
        if (errorJson && typeof failed.code === "number" && failed.stdout?.trim())
            return failed.stdout;
        throw new Error((failed.stderr?.trim() || failed.message).slice(0, 2000), { cause: error });
    }
}
const caller = (config) => async (args, signal, options = {}) => {
    const { client, socket } = config;
    if (!existsSync(client))
        throw new Error(`The native desktop client is missing at ${client}.`);
    if (!existsSync(socket)) {
        throw new Error(`Open ${config.name ?? "the desktop host app"} on this host to enable native desktop tools.`);
    }
    signal.throwIfAborted();
    options.onDispatch?.();
    const output = await run(client, [socket, ...args], signal, true, options.input, config.agent);
    let value;
    try {
        value = JSON.parse(output);
    }
    catch {
        throw new Error("The native desktop client returned invalid JSON.");
    }
    if (!value || typeof value.success !== "boolean") {
        throw new Error("The native desktop client returned an unsupported response.");
    }
    if (!value.success) {
        const error = value.error;
        const reason = error ? `${error.code}: ${error.message}` : "Native desktop operation failed";
        const name = config.name ?? "the desktop host app";
        const permission = error?.code.toLowerCase().includes("permission")
            ? args[0] === "clipboard"
                ? ` Check the clipboard access of ${name} in macOS Settings.`
                : ` Check the Accessibility and Screen Recording access of ${name}.`
            : "";
        throw new NativeError(error?.code || "DESKTOP_ERROR", `${reason}.${permission}`);
    }
    if (!value.data || typeof value.data !== "object") {
        throw new Error("The native desktop client returned no desktop data.");
    }
    const { target } = options;
    if (target) {
        const receipt = value.target_receipt;
        if (!receipt) {
            throw new Error("Native inspection returned no exact-window receipt.");
        }
        if (receipt.pid !== target.pid || receipt.window_id !== target.window) {
            throw new Error("Native inspection returned a different application or window. Refresh the desktop inventory and select the target again.");
        }
    }
    return {
        ...value.data,
        ...(value.target_receipt ? { target_receipt: value.target_receipt } : {}),
    };
};
function bounded(data, field, limit = MAX_TEXT) {
    const source = data[field];
    if (!Array.isArray(source))
        throw new Error(`Native inspection returned no ${field} array.`);
    const values = [...source];
    const value = { ...data, [field]: values };
    let text = JSON.stringify(value);
    while (Buffer.byteLength(text) > limit && values.length) {
        values.pop();
        text = JSON.stringify({
            ...value,
            truncated: true,
            omitted: source.length - values.length,
        });
    }
    if (Buffer.byteLength(text) > limit) {
        throw new Error("Native inspection metadata exceeds the result limit.");
    }
    return text;
}
function validateScope(scope) {
    if (!scope || typeof scope !== "object" || Object.keys(scope).length !== 2
        || !("snapshot" in scope) || !("element" in scope)
        || [scope.snapshot, scope.element].some((value) => typeof value !== "string" || !value || value.length > 256 || /\s/.test(value))) {
        throw new Error("Choose scope as the snapshot_id and an element ID from an earlier desktop_inspect of this window.");
    }
}
/** Recognized text must arrive within its native limits, or it is dropped from the result. */
function recognizedLimit(data, requested) {
    if (!requested) {
        if (data.recognized_text !== undefined)
            throw new Error("Native observation returned unrequested recognized text.");
        return 0;
    }
    const size = Buffer.byteLength(JSON.stringify(data.recognized_text ?? null));
    if (data.recognized_text === undefined || size > MAX_RECOGNIZED_TEXT) {
        data.recognized_text = { error: "Recognized text was missing or exceeded its result limit." };
    }
    return MAX_RECOGNIZED_TEXT;
}
function positive(value) {
    if (!Number.isSafeInteger(value) || value < 1) {
        throw new Error("Choose a positive application PID and window ID from the desktop inventory.");
    }
    return String(value);
}
async function screenshot(input, output, signal) {
    const file = await stat(input);
    if (!file.isFile() || file.size > 32_000_000) {
        throw new Error("The native screenshot is missing or too large.");
    }
    // A single result must fit the hosted channel's 2 MB SQLite row, including its base64 image.
    for (const size of [1600, 1200, 800]) {
        await run("/usr/bin/sips", [
            "-s",
            "format",
            "jpeg",
            "-s",
            "formatOptions",
            "70",
            "--resampleHeightWidthMax",
            String(size),
            input,
            "--out",
            output,
        ], signal);
        if ((await stat(output)).size > MAX_IMAGE)
            continue;
        const info = await run("/usr/bin/sips", ["-g", "pixelWidth", "-g", "pixelHeight", output], signal);
        const width = Number(/pixelWidth:\s*(\d+)/.exec(info)?.[1]);
        const height = Number(/pixelHeight:\s*(\d+)/.exec(info)?.[1]);
        if (!width || !height)
            throw new Error("Could not read the screenshot dimensions.");
        const bytes = await readFile(output);
        if (bytes.length > MAX_IMAGE) {
            throw new Error("The resized screenshot exceeds the result limit.");
        }
        return { image: { mimeType: "image/jpeg", data: bytes.toString("base64") }, width, height };
    }
    throw new Error("The screenshot could not be resized within the result limit.");
}
function clipboardFiles(data) {
    const files = data.files;
    if (typeof data.present !== "boolean" || !Number.isSafeInteger(data.change_count)
        || (data.present
            ? !Array.isArray(files) || !files.length || files.length > 32
                || files.some((file) => !file || typeof file.url !== "string" || typeof file.path !== "string"
                    || !file.path.startsWith("/"))
            : files !== undefined))
        throw new Error("The native clipboard file read returned an unsupported response.");
    const text = JSON.stringify(data);
    if (Buffer.byteLength(text) > 24_000) {
        throw new Error("Clipboard file references exceed the complete 24 KB result limit.");
    }
    return { text };
}
function clipboardImage(data) {
    if (typeof data.present !== "boolean" || !Number.isSafeInteger(data.change_count)) {
        throw new Error("The native clipboard image read returned an unsupported response.");
    }
    if (!data.present) {
        if (data.image !== undefined || data.source !== undefined) {
            throw new Error("An absent clipboard image returned unexpected image data.");
        }
        return { text: JSON.stringify(data) };
    }
    const preview = data.image;
    const source = data.source;
    if (!preview || !source || typeof preview.data !== "string"
        || !["image/png", "image/jpeg"].includes(String(preview.mimeType))
        || ![preview.width, preview.height].every((value) => typeof value === "number" && Number.isSafeInteger(value) && value > 0 && value <= 1600)
        || preview.data.length > Math.ceil(MAX_IMAGE / 3) * 4)
        throw new Error("The native clipboard image preview is missing or exceeds its limits.");
    const bytes = Buffer.from(preview.data, "base64");
    if (!bytes.length || bytes.length > MAX_IMAGE || bytes.length !== preview.bytes
        || bytes.toString("base64") !== preview.data)
        throw new Error("The native clipboard image preview is not a complete bounded image.");
    const { data: encoded, ...metadata } = preview;
    const text = JSON.stringify({
        present: true,
        change_count: data.change_count,
        source,
        preview: metadata,
    });
    if (Buffer.byteLength(text) > MAX_TEXT) {
        throw new Error("The clipboard image metadata exceeds the result limit.");
    }
    return { text, image: { mimeType: preview.mimeType, data: encoded } };
}
async function inspect(native, request, signal) {
    const pid = positive(request.pid);
    const window = positive(request.window);
    const mode = request.mode ?? "accessibility";
    if (mode !== "accessibility" && mode !== "pixels") {
        throw new Error("Choose accessibility or pixels inspection mode.");
    }
    if (request.ocr !== undefined && typeof request.ocr !== "boolean")
        throw new Error("Choose ocr true or false.");
    if (request.scope !== undefined) {
        validateScope(request.scope);
        if (mode !== "accessibility")
            throw new Error("A scope needs accessibility mode.");
    }
    const directory = await mkdtemp(join(tmpdir(), "desktop-tools-"));
    try {
        const path = join(directory, "capture.png");
        const args = ["inspect", pid, window, path, mode];
        if (request.ocr)
            args.push("ocr");
        if (request.scope)
            args.push("scope", request.scope.snapshot, request.scope.element);
        const data = await native(args, signal, { target: request });
        if (request.scope && data.scope?.from_element !== request.scope.element) {
            throw new Error("Native inspection did not honor the requested scope.");
        }
        const limit = (request.scope ? MAX_SCOPED_TEXT : MAX_TEXT) + recognizedLimit(data, request.ocr);
        const { image, width, height } = await screenshot(path, join(directory, "image.jpg"), signal);
        const { screenshot_raw: _raw, screenshot_annotated: _annotated, ...observation } = data;
        const text = bounded({
            ...observation,
            ace_image: {
                width,
                height,
                note: "Screenshot resized; Accessibility bounds remain in their original coordinate system. Pointer points use fractions of this image: x from the left edge and y from the top, each >= 0 and < 1.",
            },
        }, "ui_elements", limit);
        return { text, image };
    }
    catch (error) {
        if (!(error instanceof NativeError))
            throw error;
        return {
            isError: true,
            text: JSON.stringify({
                inspection_error: { code: error.code, message: error.message.slice(0, 4000) },
                requested_target: {
                    pid: request.pid,
                    window_id: request.window,
                    mode,
                    ...(request.scope ? { scope: request.scope } : {}),
                },
                target_availability: await availability(native, request, signal),
                guidance: "This inspection dispatched no input and returned no observation snapshot. Availability was read after the failure and does not establish its cause. Refresh desktop_apps and desktop_windows if the target changed. Retry an incomplete Accessibility read once; pixels mode can inspect the same exact window without Accessibility, with point-only action authority. Native capture already retries a changed capture receipt once. Neither mode activates a window. Do not loop on an unavailable target or repeat an earlier action to recover an observation.",
            }),
        };
    }
    finally {
        await rm(directory, { recursive: true, force: true });
    }
}
async function screen(native, request, signal) {
    const display = request.display;
    if (display !== undefined && (!Number.isInteger(display) || display < 0 || display > 63)) {
        throw new Error("Choose a display index from 0 to 63 from the returned displays list.");
    }
    if (request.ocr !== undefined && typeof request.ocr !== "boolean")
        throw new Error("Choose ocr true or false.");
    const directory = await mkdtemp(join(tmpdir(), "desktop-tools-"));
    try {
        const path = join(directory, "capture.png");
        const args = ["screen", path];
        if (display !== undefined)
            args.push(String(display));
        if (request.ocr)
            args.push("ocr");
        const data = await native(args, signal);
        const limit = MAX_TEXT + recognizedLimit(data, request.ocr);
        const { image, width, height } = await screenshot(path, join(directory, "image.jpg"), signal);
        const text = bounded({
            ...data,
            ace_image: {
                width,
                height,
                note: "Whole-display screenshot, resized. Observation only: there is no snapshot_id and no input can target this image. Window and display bounds are global desktop points; pass a window's pid and window_id to desktop_inspect to act on it.",
            },
        }, "windows", limit);
        return { text, image };
    }
    finally {
        await rm(directory, { recursive: true, force: true });
    }
}
async function read(native, request, signal) {
    const args = ["read", positive(request.pid), positive(request.window)];
    if (request.scope !== undefined) {
        validateScope(request.scope);
        args.push(request.scope.snapshot, request.scope.element);
    }
    let data;
    try {
        data = await native(args, signal, { target: request });
    }
    catch (error) {
        if (!(error instanceof NativeError))
            throw error;
        return {
            isError: true,
            text: JSON.stringify({
                read_error: { code: error.code, message: error.message.slice(0, 4000) },
                requested_target: {
                    pid: request.pid,
                    window_id: request.window,
                    ...(request.scope ? { scope: request.scope } : {}),
                },
                guidance: "This read sent no input. Refresh desktop_windows if the target changed, and retry once if Accessibility was incomplete. A window without Accessibility, such as a canvas, game or remote desktop, has no text to read; use desktop_inspect with mode pixels and ocr true to recognize its text from pixels.",
            }),
        };
    }
    const scope = data.scope;
    if (typeof data.text !== "string" || typeof data.truncated !== "boolean"
        || (request.scope ? scope?.element !== request.scope.element : scope !== undefined))
        throw new Error("The native read returned an unsupported response.");
    const text = JSON.stringify(data);
    if (Buffer.byteLength(text) > MAX_READ_TEXT)
        throw new Error("The native read exceeds the result limit.");
    return { text };
}
function validatePoint(point) {
    if (!point || typeof point !== "object" || !("x" in point) || !("y" in point)) {
        throw new Error("Choose a normalized screenshot point with x and y coordinates.");
    }
    for (const value of [point.x, point.y]) {
        if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value >= 1) {
            throw new Error("Screenshot point coordinates must be at least 0 and less than 1.");
        }
    }
}
async function availability(native, request, signal) {
    if (signal.aborted)
        return { error: "The desktop call ended before availability could be read." };
    const deadline = new AbortController();
    const timer = setTimeout(() => deadline.abort(), 3500);
    try {
        const context = AbortSignal.any([signal, deadline.signal]);
        const results = await Promise.allSettled([
            native(["apps"], context),
            native(["windows", String(request.pid)], context),
        ]);
        const result = { observed_at: new Date().toISOString() };
        for (const [index, field, key, id, fields] of [
            [0, "apps", "pid", request.pid, [
                    "pid",
                    "is_active",
                    "is_active_known",
                    "is_hidden",
                    "is_hidden_known",
                    "process_start_identity_decimal",
                ]],
            [1, "windows", "window_id", request.window, [
                    "window_id",
                    "bounds",
                    "is_on_screen",
                    "is_minimized",
                    "is_key",
                    "observation_capability",
                    "observation_reason",
                    "process_start_identity_decimal",
                ]],
        ]) {
            const value = results[index];
            if (value.status === "rejected") {
                result[field] = { error: String(value.reason).slice(0, 500) };
                continue;
            }
            const items = value.value[field];
            if (!Array.isArray(items)) {
                result[field] = { error: "Native inventory returned no items." };
                continue;
            }
            const item = items.find((item) => item[key] === id);
            result[field] = {
                inventory_completeness: value.value.inventory_completeness,
                target: item ? Object.fromEntries(fields.map((field) => [field, item[field]])) : null,
            };
        }
        return result;
    }
    finally {
        clearTimeout(timer);
    }
}
function validateApplication(application) {
    if (!application || typeof application !== "object" || Object.keys(application).length !== 1) {
        throw new Error("Use exactly one application path or bundle_id.");
    }
    if ("path" in application) {
        const path = application.path;
        if (typeof path !== "string" || path.length > 4096 || !path.startsWith("/")
            || !path.toLowerCase().endsWith(".app") || path.includes("\0"))
            throw new Error("Use an absolute .app path for launch.");
    }
    else if (!("bundle_id" in application) || typeof application.bundle_id !== "string"
        || application.bundle_id.length > 256
        || !/^[A-Za-z0-9.-]+$/.test(application.bundle_id))
        throw new Error("Use an exact application bundle ID for launch.");
}
function validateKey(request) {
    if (!isDesktopKey(request.key))
        throw new Error("Choose a named key or one printable character.");
    validateModifiers(request.modifiers);
}
function validateModifiers(modifiers) {
    if (modifiers !== undefined && (!Array.isArray(modifiers) || modifiers.length > 4
        || new Set(modifiers).size !== modifiers.length
        || modifiers.some((modifier) => !DESKTOP_MODIFIERS.includes(modifier)))) {
        throw new Error("Use each of command, control, option, and shift at most once.");
    }
}
function validateAction(request) {
    if (request.op === "launch") {
        if (Object.keys(request).some((key) => !["op", "application"].includes(key))) {
            throw new Error("Launch accepts exactly one application path or bundle_id.");
        }
        validateApplication(request.application);
        return;
    }
    if (request.op === "open") {
        const item = request.item;
        if (Object.keys(request).some((key) => !["op", "item", "application"].includes(key))
            || !item || typeof item !== "object" || Object.keys(item).length !== 1)
            throw new Error("Open accepts exactly one item path or url and an optional application.");
        if ("path" in item) {
            if (typeof item.path !== "string" || item.path.length > 4096
                || !item.path.startsWith("/") || item.path.includes("\0"))
                throw new Error("Use an existing absolute item path.");
        }
        else if (!("url" in item) || typeof item.url !== "string" || item.url.length > 4096
            || !/^[A-Za-z][A-Za-z0-9+.-]*:/.test(item.url)
            || /\p{Cc}/u.test(item.url)) {
            throw new Error("Use a complete absolute URL with an explicit scheme and no control characters.");
        }
        if (request.application !== undefined)
            validateApplication(request.application);
        if (Buffer.byteLength(JSON.stringify(request)) > 16_384) {
            throw new Error("The open request exceeds 16 KiB.");
        }
        return;
    }
    if (request.op === "dialog-answer") {
        validateDialogTarget(request.target);
        const keys = Object.keys(request).filter((key) => key !== "op" && key !== "target").sort();
        if ("button" in request && keys.length === 1) {
            if (typeof request.button !== "string" || !request.button || request.button.length > 512)
                throw new Error("Use one exact dialog button title of at most 512 UTF-16 code units.");
            return;
        }
        if ("path" in request && keys.length === 1) {
            if (typeof request.path !== "string" || !request.path.startsWith("/") || request.path.includes("\0")
                || Buffer.byteLength(request.path) > 4096)
                throw new Error("Use one absolute file-dialog path of at most 4096 bytes.");
            return;
        }
        if (!("field" in request) || keys.join() !== "field,text" || !Number.isInteger(request.field)
            || request.field < 0 || request.field > 1000 || typeof request.text !== "string"
            || request.text.length > 8192) {
            throw new Error("Answer a dialog with exactly one button title, one listed field index and at most 8192 UTF-16 code units of text, or one path.");
        }
        return;
    }
    if (request.op === "menu") {
        validateAppOnly(request.target);
        validateMenuPath(request.path);
        if (Buffer.byteLength(JSON.stringify(request)) > 4096) {
            throw new Error("Menu request exceeds the 4096-byte limit.");
        }
        return;
    }
    if (request.op === "menubar-click") {
        if (Object.keys(request).some((key) => !["op", "target"].includes(key))) {
            throw new Error("Menu bar click accepts only the status item's target.");
        }
        return validateStatusItem(request.target);
    }
    if (request.op === "dock") {
        validateDock(request);
        if (request.title === undefined)
            throw new Error("Choose a Dock item title to act on.");
        return;
    }
    if (isDesktopManagement(request))
        return validateManagement(request);
    if (request.op === "clipboard-write") {
        if ("format" in request) {
            if (request.format === "files") {
                if ("text" in request || "path" in request || !Array.isArray(request.paths)
                    || !request.paths.length || request.paths.length > 32
                    || request.paths.some((path) => typeof path !== "string" || !path.startsWith("/") || path.length > 4096
                        || path.includes("\0")))
                    throw new Error("Use format files with 1–32 absolute paths and no text or image path.");
                return;
            }
            if (request.format !== "image" || "text" in request || "paths" in request
                || typeof request.path !== "string"
                || !request.path.startsWith("/") || request.path.length > 4096
                || request.path.includes("\0"))
                throw new Error("Use format image with one absolute image path and no text.");
            return;
        }
        if ("path" in request || "paths" in request || typeof request.text !== "string"
            || request.text.length > 8192) {
            throw new Error("Clipboard text must contain at most 8192 UTF-16 code units.");
        }
        return;
    }
    if (request.op === "system-key") {
        if (Object.keys(request).some((key) => !["op", "key", "modifiers"].includes(key))) {
            throw new Error("A system key accepts only key and modifiers.");
        }
        return validateKey(request);
    }
    if (typeof request.snapshot !== "string" || !request.snapshot || request.snapshot.length > 256) {
        throw new Error("Use the snapshot_id from a fresh desktop_inspect result.");
    }
    if (request.op === "drag") {
        validatePoint(request.from);
        validatePoint(request.to);
        if (request.to_snapshot !== undefined
            && (typeof request.to_snapshot !== "string" || !request.to_snapshot
                || request.to_snapshot.length > 256 || request.to_snapshot === request.snapshot)) {
            throw new Error("Use another window's snapshot_id as to_snapshot, or omit it to drag within one window.");
        }
        if (request.path !== undefined) {
            if (!Array.isArray(request.path) || request.path.length < 1 || request.path.length > 16) {
                throw new Error("Give a drag path of 1 to 16 normalized screenshot points.");
            }
            if (request.to_snapshot !== undefined) {
                throw new Error("A drag path stays in one window; omit path to drag into another window.");
            }
            request.path.forEach(validatePoint);
        }
        if (request.to_snapshot === undefined && request.path === undefined
            && request.from.x === request.to.x && request.from.y === request.to.y) {
            throw new Error("Choose distinct start and end points for a drag.");
        }
        validateModifiers(request.modifiers);
        if (request.button !== undefined && !DESKTOP_BUTTONS.includes(request.button)) {
            throw new Error("Choose the left or right mouse button for a drag.");
        }
        if (request.duration_ms !== undefined
            && (!Number.isInteger(request.duration_ms) || request.duration_ms < 1
                || request.duration_ms > 10000)) {
            throw new Error("Drag duration must be 1 to 10000 milliseconds.");
        }
        return;
    }
    if (request.op === "hover" || request.op === "press") {
        if ((request.element === undefined) === (request.point === undefined)) {
            throw new Error("Choose exactly one observed element ID or normalized screenshot point.");
        }
        if (request.point !== undefined)
            validatePoint(request.point);
        else if (typeof request.element !== "string" || !request.element || request.element.length > 256) {
            throw new Error("Choose an element ID from the inspected snapshot.");
        }
        if (request.op === "press") {
            if (request.button !== undefined && !DESKTOP_BUTTONS.includes(request.button)) {
                throw new Error("Choose the left or right mouse button for a press.");
            }
            if (request.duration_ms !== undefined
                && (!Number.isInteger(request.duration_ms) || request.duration_ms < 1
                    || request.duration_ms > 10000)) {
                throw new Error("Press duration must be 1 to 10000 milliseconds.");
            }
        }
        return;
    }
    if (request.op === "click" || request.op === "scroll") {
        if ((request.element === undefined) === (request.point === undefined)) {
            throw new Error("Choose exactly one observed element ID or normalized screenshot point.");
        }
        if (request.point !== undefined)
            validatePoint(request.point);
        else if (typeof request.element !== "string" || !request.element || request.element.length > 256) {
            throw new Error("Choose an element ID from the inspected snapshot.");
        }
        if (request.op === "click") {
            if (request.kind !== undefined && !DESKTOP_CLICKS.includes(request.kind)) {
                throw new Error("Choose single, double, right, middle, or triple click.");
            }
        }
        else if (!DESKTOP_DIRECTIONS.includes(request.direction) || !Number.isInteger(request.amount)
            || request.amount < 1 || request.amount > 20) {
            throw new Error("Choose up, down, left, or right and 1 to 20 native scroll units.");
        }
        return;
    }
    if (request.op === "key")
        return validateKey(request);
    if (request.op === "insert") {
        if (typeof request.text !== "string" || !request.text || request.text.length > 8192) {
            throw new Error("Inserted text must contain 1 to 8192 UTF-16 code units.");
        }
        return;
    }
    if (typeof request.element !== "string" || !request.element || request.element.length > 256) {
        throw new Error("Choose an element ID from the inspected snapshot.");
    }
    if (request.op === "element-action" && !DESKTOP_ELEMENT_ACTIONS.includes(request.action)) {
        throw new Error(`Choose one of ${DESKTOP_ELEMENT_ACTIONS.join(", ")}.`);
    }
    if (request.op === "set-value" && typeof request.value !== "boolean"
        && (typeof request.value !== "number" || !Number.isFinite(request.value))) {
        throw new Error("Set a finite number or true/false; use desktop_type for text.");
    }
    if (request.op === "type" && (typeof request.text !== "string" || request.text.length > 8192)) {
        throw new Error("Replacement text must contain at most 8192 UTF-16 code units.");
    }
    if (request.op === "select") {
        if (typeof request.text !== "string" || !request.text || request.text.length > 4096) {
            throw new Error("Selection text must contain 1 to 4096 UTF-16 code units.");
        }
        for (const context of [request.prefix, request.suffix]) {
            if (context !== undefined && (typeof context !== "string" || context.length > 2048)) {
                throw new Error("Selection context must contain at most 2048 UTF-16 code units.");
            }
        }
        if (request.selection !== undefined && !DESKTOP_SELECTIONS.includes(request.selection)) {
            throw new Error("Choose text, cursor_before, or cursor_after for selection.");
        }
    }
}
function validateMenuPath(path) {
    if (!Array.isArray(path) || !path.length || path.length > 8
        || path.some((title) => typeof title !== "string" || !title.trim() || title.length > 512)) {
        throw new Error("Menu path requires 1 to 8 nonblank literal titles of at most 512 UTF-16 code units each.");
    }
}
function validateAppTarget(target) {
    if (!target || typeof target !== "object" || !Number.isInteger(target.pid)
        || target.pid < 1 || target.pid > 2_147_483_647
        || typeof target.process_start_identity_decimal !== "string"
        || !/^[1-9][0-9]{0,19}$/.test(target.process_start_identity_decimal)
        || BigInt(target.process_start_identity_decimal) > 18446744073709551615n)
        throw new Error("Pass the application's target object from fresh desktop inventory unchanged.");
}
function validateAppOnly(target) {
    validateAppTarget(target);
    if (Object.keys(target).some((key) => !["pid", "process_start_identity_decimal"].includes(key))) {
        throw new Error("Pass only the application's target object from desktop_apps.");
    }
}
function validateStatusItem(target) {
    validateAppTarget(target);
    if (Object.keys(target).some((key) => !["pid", "process_start_identity_decimal", "window_id", "index"].includes(key))
        || (target.window_id !== undefined
            && (!Number.isInteger(target.window_id) || target.window_id < 1 || target.window_id > 4_294_967_295))
        || !Number.isInteger(target.index) || target.index < 0
        || target.index > 1000)
        throw new Error("Pass the status item's target object from desktop_menubar_items unchanged.");
}
function validateDockTitle(value, name) {
    if (typeof value !== "string" || !value.trim() || value.trim() !== value || value.length > 512
        || /\p{Cc}/u.test(value)) {
        throw new Error(`${name} must be a nonblank literal title of at most 512 UTF-16 units, without surrounding whitespace.`);
    }
}
function validateDock(request) {
    if (Object.keys(request).some((key) => !["op", "title", "menu_item"].includes(key))) {
        throw new Error("Dock accepts only title and menu_item.");
    }
    if (request.title !== undefined)
        validateDockTitle(request.title, "title");
    if (request.menu_item !== undefined) {
        if (request.title === undefined) {
            throw new Error("menu_item requires the title of the Dock item to right-click.");
        }
        validateDockTitle(request.menu_item, "menu_item");
    }
}
function validateDialogTarget(target) {
    if (target && typeof target === "object" && "window_id" in target)
        validateWindowTarget(target);
    else
        validateAppOnly(target);
}
function validateWindowTarget(window) {
    validateAppTarget(window);
    if (!Number.isInteger(window.window_id) || window.window_id < 1 || window.window_id > 4_294_967_295
        || typeof window.is_minimized !== "boolean" || !window.bounds
        || ![window.bounds.x, window.bounds.y, window.bounds.width, window.bounds.height].every(Number.isFinite)
        || window.bounds.width <= 0 || window.bounds.height <= 0) {
        throw new Error("Pass the window's target object, including its original bounds, from desktop_windows unchanged.");
    }
}
function validateManagement(request) {
    if (request.op === "activate" || request.op === "quit" || request.op === "hide"
        || request.op === "unhide") {
        validateAppOnly(request.target);
        if (request.op === "quit" && request.force !== undefined && typeof request.force !== "boolean") {
            throw new Error("Quit force must be true or false.");
        }
        return;
    }
    validateWindowTarget(request.target);
    if (request.op === "move") {
        const position = request.position;
        if (!position || ![position.x, position.y].every(Number.isFinite)) {
            throw new Error("Window position must contain finite x and y in desktop logical points.");
        }
    }
    if (request.op === "resize") {
        const size = request.size;
        if (!size || ![size.width, size.height].every(Number.isFinite) || size.width <= 0
            || size.height <= 0) {
            throw new Error("Window size must contain positive finite width and height in desktop logical points.");
        }
    }
}
function actionResult(data, outcome) {
    let text = JSON.stringify({ action: data });
    if (Buffer.byteLength(text) > MAX_TEXT) {
        text = JSON.stringify({
            action: {
                outcome,
                target_receipt: data.target_receipt,
                terminated: data.terminated,
                clipboard_changed: data.clipboard_changed,
                clipboard_cleanup: data.clipboard_cleanup,
                clipboard_ownership: data.clipboard_ownership,
                consumption: data.consumption,
                created_windows: data.created_windows,
            },
            warning: "Native action metadata exceeded the result limit. Inspect the current state.",
        });
    }
    return { text, outcome, isError: outcome !== "completed" };
}
async function clipboardImageInput(path, signal) {
    signal.throwIfAborted();
    // Nonblocking open prevents a named pipe from waiting before its regular-file check.
    const file = await open(path, constants.O_RDONLY | constants.O_NONBLOCK);
    try {
        signal.throwIfAborted();
        const before = await file.stat({ bigint: true });
        if (!before.isFile() || before.size <= 0n || before.size > BigInt(MAX_CLIPBOARD_IMAGE)) {
            throw new Error("Clipboard images require a nonempty regular file of at most 10 MiB.");
        }
        const bytes = Buffer.alloc(Number(before.size) + 1);
        let size = 0;
        while (size < bytes.length) {
            signal.throwIfAborted();
            const read = await file.read(bytes, size, bytes.length - size, size);
            if (!read.bytesRead)
                break;
            size += read.bytesRead;
        }
        const after = await file.stat({ bigint: true });
        signal.throwIfAborted();
        if (size !== Number(before.size) || after.size !== before.size
            || after.mtimeNs !== before.mtimeNs || after.ctimeNs !== before.ctimeNs) {
            throw new Error("The image file changed while being read; choose a stable file before writing.");
        }
        return bytes.subarray(0, size).toString("base64");
    }
    finally {
        await file.close();
    }
}
async function act(native, request, signal) {
    if (request.op === "menubar-click")
        return await menubarClick(native, request, signal);
    let dispatched = false;
    let data;
    try {
        validateAction(request);
        if (request.op === "clipboard-write" && "format" in request && request.format === "files") {
            for (const path of request.paths) {
                signal.throwIfAborted();
                const entry = await lstat(path);
                if (!entry.isFile() && !entry.isDirectory() && !entry.isSymbolicLink()) {
                    throw new Error("Clipboard file references require existing files, directories, or symbolic links.");
                }
            }
            signal.throwIfAborted();
        }
        const input = request.op === "clipboard-write" && "format" in request && request.format === "image"
            ? {
                op: request.op,
                format: request.format,
                image: await clipboardImageInput(request.path, signal),
            }
            : request;
        const operation = request.op === "menu"
            ? "menu"
            : request.op === "dialog-answer"
                ? "dialog"
                : request.op === "dock"
                    ? "dock"
                    : request.op === "clipboard-write"
                        ? "clipboard"
                        : request.op === "launch"
                            ? "launch"
                            : request.op === "open"
                                ? "open"
                                : request.op === "system-key"
                                    ? "system-key"
                                    : isDesktopManagement(request)
                                        ? "management"
                                        : "action";
        data = await native([operation], signal, {
            input: JSON.stringify(input),
            onDispatch() {
                dispatched = true;
            },
        });
        if (!["completed", "refused", "unknown"].includes(String(data.outcome))) {
            throw new Error("The native desktop client returned no action outcome.");
        }
    }
    catch (error) {
        // The client reports a dialect mismatch after its handshake and before any request.
        const sent = dispatched
            && !(error instanceof NativeError && error.code === "DESKTOP_PROTOCOL_MISMATCH");
        const outcome = sent ? "unknown" : "refused";
        return actionResult({
            outcome,
            reason: (error instanceof Error ? error.message : String(error)).slice(0, 2000),
            message: sent && request.op === "launch"
                ? "The launch may still finish and open the app later. Observe desktop_apps before any further action; do not blindly repeat the launch."
                : sent && request.op === "open"
                    ? "The item may still open later. Observe desktop_apps before any further action; do not blindly repeat the open."
                    : sent
                        ? "The desktop action may have partially run. Inspect the current state before retrying. Stopping does not undo input already delivered."
                        : "The desktop action was not sent to the native desktop.",
        }, outcome);
    }
    const outcome = data.outcome;
    if (request.op === "menu") {
        const receipt = data.target_receipt;
        if ((outcome === "completed" || receipt) && (!receipt || receipt.window_id !== undefined
            || receipt.pid !== request.target.pid
            || receipt.process_start_identity_decimal !== request.target.process_start_identity_decimal)) {
            return actionResult({
                ...data,
                outcome: "unknown",
                receipt_error: "The menu command returned a different application receipt. Observe the intended app before any further action.",
            }, "unknown");
        }
        return actionResult(data, outcome);
    }
    // The Dock receipt names the Dock process; desktop_apps shows what the press launched or activated.
    if (request.op === "dock")
        return actionResult(data, outcome);
    if (outcome === "unknown"
        && ((request.op === "quit" && data.terminated === false)
            || ((request.op === "close" || request.op === "dialog-answer") && data.target_receipt))) {
        return await observeManagement(native, request, data, signal);
    }
    if (outcome !== "completed" || request.op === "clipboard-write") {
        return actionResult(data, outcome);
    }
    if (isDesktopManagement(request) || request.op === "launch" || request.op === "open"
        || request.op === "dialog-answer") {
        return await observeManagement(native, request, data, signal);
    }
    // Observation is separate from delivery: its failure must not turn completed input into a retry.
    try {
        const receipt = data.target_receipt;
        if (!receipt?.process_start_identity_decimal || !receipt.window_id) {
            throw new Error("No exact-window action receipt.");
        }
        const observation = await inspect(native, {
            op: "inspect",
            pid: receipt.pid,
            window: receipt.window_id,
        }, signal);
        const fresh = JSON.parse(observation.text);
        if (observation.isError) {
            return actionResult({
                ...data,
                observation_error: fresh,
                message: "The action completed, but a fresh observation was unavailable. Inspect again to verify the result; do not repeat the action blindly.",
            }, outcome);
        }
        const current = fresh.target_receipt;
        if (current?.process_start_identity_decimal !== receipt.process_start_identity_decimal) {
            throw new Error("The target application changed after the action.");
        }
        return {
            text: bounded({ ...fresh, action: data }, "ui_elements"),
            image: observation.image,
            outcome,
            isError: false,
        };
    }
    catch (error) {
        return actionResult({
            ...data,
            observation_error: (error instanceof Error ? error.message : String(error)).slice(0, 2000),
            message: "The action completed, but a fresh observation was unavailable. Inspect again to verify the result; do not repeat the action blindly.",
        }, outcome);
    }
}
async function menubarClick(native, request, signal) {
    let dispatched = false;
    let directory;
    try {
        let data;
        try {
            validateAction(request);
            directory = await mkdtemp(join(tmpdir(), "desktop-tools-"));
            data = await native(["menubar-click", join(directory, "capture.png")], signal, {
                input: JSON.stringify(request),
                onDispatch() {
                    dispatched = true;
                },
            });
            if (!["completed", "refused", "unknown"].includes(String(data.outcome))) {
                throw new Error("The native desktop client returned no action outcome.");
            }
        }
        catch (error) {
            const sent = dispatched
                && !(error instanceof NativeError && error.code === "DESKTOP_PROTOCOL_MISMATCH");
            const outcome = sent ? "unknown" : "refused";
            return actionResult({
                outcome,
                reason: (error instanceof Error ? error.message : String(error)).slice(0, 2000),
                message: sent
                    ? "The click may have opened the item's menu. Observe with desktop_screen before any further action; do not blindly repeat it, because a second click usually closes the menu."
                    : "The desktop action was not sent to the native desktop.",
            }, outcome);
        }
        const outcome = data.outcome;
        const receipt = data.target_receipt;
        const target = request.target;
        if ((outcome === "completed" || receipt) && (!receipt || receipt.pid !== target.pid
            || (receipt.window_id ?? undefined) !== target.window_id
            || receipt.process_start_identity_decimal !== target.process_start_identity_decimal)) {
            return actionResult({
                ...data,
                outcome: "unknown",
                receipt_error: "The status item click returned a different receipt. Observe the menu bar before any further action.",
            }, "unknown");
        }
        const opened = data.opened;
        if (!opened?.capture)
            return actionResult(data, outcome);
        // The capture is observation only; its failure must not turn a delivered click into a retry.
        try {
            const { image, width, height } = await screenshot(join(directory, "capture.png"), join(directory, "image.jpg"), signal);
            const text = JSON.stringify({
                action: data,
                ace_image: {
                    width,
                    height,
                    note: "Screenshot of the region that opened after the click, resized. Observation only: there is no snapshot_id and no input can target this image.",
                },
            });
            if (Buffer.byteLength(text) > MAX_TEXT)
                return actionResult(data, outcome);
            return { text, image, outcome, isError: outcome !== "completed" };
        }
        catch (error) {
            return actionResult({
                ...data,
                observation_error: (error instanceof Error ? error.message : String(error)).slice(0, 2000),
            }, outcome);
        }
    }
    finally {
        if (directory)
            await rm(directory, { recursive: true, force: true });
    }
}
async function observeManagement(native, request, action, signal) {
    const data = { action };
    const outcome = action.outcome === "unknown" ? "unknown" : "completed";
    const receipt = action.target_receipt;
    const target = request.op === "launch" || request.op === "open"
        ? action.application?.target
        : request.target;
    const applicationLevel = request.op === "activate" || request.op === "quit"
        || request.op === "hide" || request.op === "unhide" || request.op === "launch"
        || request.op === "open";
    if (!receipt || !target || receipt.pid !== target.pid
        || receipt.process_start_identity_decimal !== target.process_start_identity_decimal
        || (applicationLevel
            ? receipt.window_id !== undefined
            : request.op === "dialog-answer" && !("window_id" in request.target)
                ? !receipt.window_id
                : receipt.window_id !== request.target.window_id)) {
        return actionResult({
            ...action,
            outcome: "unknown",
            reason: "The native action returned a different target receipt. Refresh the target before any retry.",
        }, "unknown");
    }
    try {
        const apps = await native(["apps"], signal);
        if (!Array.isArray(apps.apps))
            throw new Error("Native application inventory is unavailable.");
        data.application_inventory_completeness = apps.inventory_completeness;
        data.application_inventory_warnings = apps.inventory_warnings;
        const app = apps.apps.find((app) => app.pid === receipt.pid);
        data.application = app || null;
        // The native receipt owns close/quit evidence; later inventory cannot undo or establish it.
        if (!app
            && (request.op === "quit" || request.op === "close" || request.op === "dialog-answer")) {
            return managementResult(data, action, outcome);
        }
        if (!app)
            throw new Error("The target application was not returned by the later inventory.");
        if (app.process_start_identity_decimal !== receipt.process_start_identity_decimal) {
            throw new Error("The application changed process generation after the action.");
        }
        const windows = await native(["windows", String(receipt.pid)], signal);
        if (!Array.isArray(windows.windows))
            throw new Error("Native window inventory is unavailable.");
        data.window_inventory_completeness = windows.inventory_completeness;
        data.window_inventory_warnings = windows.inventory_warnings;
        data.windows = windows.windows;
        if (windows.windows.some((window) => window.process_start_identity_decimal !== receipt.process_start_identity_decimal)) {
            throw new Error("Later window inventory could not be bound to the original application generation.");
        }
        // A dialog answer can close its sheet or window, so the refreshed inventory is its observation.
        if (applicationLevel || request.op === "close" || request.op === "dialog-answer") {
            return managementResult(data, action, outcome);
        }
        if (!windows.windows.some((window) => window.window_id === receipt.window_id)) {
            throw new Error("The exact window was not returned by the later inventory.");
        }
        // Minimization intentionally removes the visible capture target; refreshed inventory owns its state.
        if (request.op === "minimize")
            return managementResult(data, action);
        const observation = await inspect(native, {
            op: "inspect",
            pid: receipt.pid,
            window: receipt.window_id,
        }, signal);
        const fresh = JSON.parse(observation.text);
        if (observation.isError) {
            data.observation_error = fresh;
            data.message =
                "The native action completed. Later inventory or inspection was unavailable; refresh the target before any further action, without repeating the completed action blindly.";
            return managementResult(data, action);
        }
        const current = fresh.target_receipt;
        if (current?.process_start_identity_decimal !== receipt.process_start_identity_decimal) {
            throw new Error("The application changed process generation before the later inspection.");
        }
        return {
            text: bounded({ ...data, ...fresh }, "ui_elements"),
            image: observation.image,
            outcome: "completed",
            isError: false,
        };
    }
    catch (error) {
        data.observation_error = (error instanceof Error ? error.message : String(error)).slice(0, 2000);
        data.message = outcome === "completed"
            ? "The native action completed. Later inventory or inspection was unavailable; refresh the target before any further action, without repeating the completed action blindly."
            : "Native completion was not confirmed and later inventory was unavailable. Refresh the target before choosing any further action; do not blindly repeat the request.";
        return managementResult(data, action, outcome);
    }
}
function managementResult(data, action, outcome = "completed") {
    try {
        const text = Array.isArray(data.windows) ? bounded(data, "windows") : JSON.stringify(data);
        if (Buffer.byteLength(text) > MAX_TEXT) {
            throw new Error("The later inventory exceeds the result limit.");
        }
        return { text, outcome, isError: outcome !== "completed" };
    }
    catch {
        return actionResult({
            ...action,
            observation_error: data.observation_error || "The later inventory exceeds the result limit.",
            message: "The native action outcome is preserved. Later inventory was omitted to fit the result limit; refresh the target without blindly repeating the action.",
        }, outcome);
    }
}
/** Creates a client bound to one host socket and signed client; calls are independent processes. */
export function createDesktop(config) {
    const native = caller(config);
    return async (request, signal) => {
        const result = await execute(native, request, signal);
        return { ...result, data: JSON.parse(result.text) };
    };
}
async function execute(native, request, abort) {
    if (!request
        || ![
            "clipboard-read",
            "clipboard-write",
            "apps",
            "windows",
            "menus",
            "menu",
            "dialog",
            "dialog-answer",
            "menubar-items",
            "menubar-click",
            "dock",
            "inspect",
            "read",
            "screen",
            "click",
            "type",
            "key",
            "system-key",
            "insert",
            "select",
            "element-action",
            "set-value",
            "scroll",
            "drag",
            "hover",
            "press",
            "activate",
            "launch",
            "open",
            "quit",
            "hide",
            "unhide",
            "close",
            "focus",
            "minimize",
            "restore",
            "maximize",
            "move",
            "resize",
        ].includes(request.op)) {
        throw new Error("Unknown native desktop request.");
    }
    if (process.platform !== "darwin") {
        const reason = "Native desktop tools require macOS 15 or later.";
        if (isDesktopAction(request))
            return actionResult({ outcome: "refused", reason }, "refused");
        throw new Error(reason);
    }
    const deadline = new AbortController();
    const timer = setTimeout(() => deadline.abort(new Error("Native desktop operation timed out after 30 seconds.")), 30_000);
    const signal = abort ? AbortSignal.any([abort, deadline.signal]) : deadline.signal;
    try {
        if (request.op === "menubar-items") {
            const data = await native(["menubar"], signal);
            return { text: bounded(data, "items") };
        }
        if (request.op === "dock" && request.title === undefined) {
            validateDock(request);
            const data = await native(["dock"], signal, { input: JSON.stringify({ op: "dock" }) });
            return { text: bounded(data, "items") };
        }
        if (isDesktopAction(request))
            return await act(native, request, signal);
        if (request.op === "inspect")
            return await inspect(native, request, signal);
        if (request.op === "screen")
            return await screen(native, request, signal);
        if (request.op === "read")
            return await read(native, request, signal);
        if (request.op === "menus") {
            validateAppOnly(request.target);
            if (request.path !== undefined)
                validateMenuPath(request.path);
            const input = JSON.stringify(request);
            if (Buffer.byteLength(input) > 4096) {
                throw new Error("Menu request exceeds the 4096-byte limit.");
            }
            const data = await native(["menus"], signal, { input });
            const target = data.target;
            if (target?.pid !== request.target.pid
                || target.process_start_identity_decimal !== request.target.process_start_identity_decimal)
                throw new Error("Native menu inventory returned a different application generation.");
            if (request.path !== undefined) {
                // An older client must not turn a scoped read into full menu disclosure.
                const path = request.path, filter = data.filter;
                if (!Array.isArray(filter?.path) || filter.path.length !== path.length
                    || filter.path.some((title, index) => title !== path[index])
                    || !Array.isArray(data.menus) || data.menus.some((row) => !Array.isArray(row?.path) || path.some((title, index) => row.path[index] !== title)))
                    throw new Error("Native menu inventory did not honor the requested literal path.");
            }
            return { text: bounded(data, "menus") };
        }
        if (request.op === "dialog") {
            validateDialogTarget(request.target);
            const data = await native(["dialog"], signal, {
                input: JSON.stringify({ op: request.op, target: request.target }),
            });
            const receipt = data.target_receipt;
            if (receipt?.pid !== request.target.pid
                || receipt.process_start_identity_decimal !== request.target.process_start_identity_decimal
                || !receipt.window_id
                || ("window_id" in request.target && receipt.window_id !== request.target.window_id))
                throw new Error("Native dialog listing returned a different application generation or window.");
            return { text: bounded(data, "other_elements") };
        }
        if (request.op === "clipboard-read") {
            if (request.format !== undefined && request.format !== "text" && request.format !== "image"
                && request.format !== "files") {
                throw new Error("Choose text, image, or files clipboard format.");
            }
            const data = await native(["clipboard"], signal, { input: JSON.stringify(request) });
            if (request.format === "image")
                return clipboardImage(data);
            if (request.format === "files")
                return clipboardFiles(data);
            if (typeof data.present !== "boolean" || !Number.isSafeInteger(data.change_count)
                || (data.present ? typeof data.text !== "string" : data.text !== undefined))
                throw new Error("The native clipboard read returned an unsupported response.");
            const text = JSON.stringify(data);
            if (Buffer.byteLength(text) > 24_000) {
                throw new Error("Clipboard text exceeds the complete 24 KB result limit.");
            }
            return { text };
        }
        let query;
        if (request.op === "apps" && request.query !== undefined) {
            if (typeof request.query !== "string" || request.query.length > 256
                || !request.query.trim()) {
                throw new Error("Application query must contain non-whitespace text and at most 256 characters.");
            }
            query = request.query.trim();
        }
        const args = request.op === "apps"
            ? ["apps"]
            : ["windows", positive(request.pid)];
        const data = await native(args, signal);
        if (query !== undefined) {
            if (!Array.isArray(data.apps)) {
                throw new Error("Native application inventory is unavailable.");
            }
            const apps = data.apps;
            const search = query.toLowerCase();
            const matches = apps.filter((app) => app.name.toLowerCase().includes(search) || app.bundle_id?.toLowerCase().includes(search));
            data.apps = matches;
            data.filter = {
                query,
                fields: ["name", "bundle_id"],
                scope: "returned_native_inventory",
                total: apps.length,
                matched: matches.length,
            };
        }
        return { text: bounded(data, request.op === "apps" ? "apps" : "windows") };
    }
    finally {
        clearTimeout(timer);
    }
}
