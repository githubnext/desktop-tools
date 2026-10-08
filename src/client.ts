import { execFile } from "node:child_process";
import { constants, existsSync } from "node:fs";
import { lstat, mkdtemp, open, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

import {
	DESKTOP_BUTTONS,
	DESKTOP_CLICKS,
	DESKTOP_DIRECTIONS,
	DESKTOP_KEYS,
	DESKTOP_MODIFIERS,
	DESKTOP_SELECTIONS,
	type DesktopAction,
	type DesktopApplication,
	type DesktopAppTarget,
	type DesktopLaunch,
	type DesktopManagement,
	type DesktopOpen,
	type DesktopOutcome,
	type DesktopRequest,
	type DesktopResult,
	isDesktopAction,
	isDesktopManagement,
} from "./protocol.js";

/** Explicit paths for one signed host and client pair; nothing is discovered. */
export type DesktopConfig = {
	/** Absolute path of the signed `desktop-tools-client`. */
	client: string;
	/** Unix socket passed to `desktop_tools_start` in the host app. */
	socket: string;
	/** Host app name used in permission guidance. */
	name?: string;
};
/** `data` is the parsed final bounded `text`; image bytes stay only in `image`. */
export type DesktopClientResult = DesktopResult & { data: unknown };
export type DesktopClient = (
	request: DesktopRequest,
	signal?: AbortSignal,
) => Promise<DesktopClientResult>;

type Native = (
	args: string[],
	signal: AbortSignal,
	options?: {
		target?: Extract<DesktopRequest, { op: "inspect" }>;
		input?: string;
		onDispatch?(): void;
	},
) => Promise<Record<string, unknown>>;

const exec = promisify(execFile);
const MAX_TEXT = 32_000;
const MAX_IMAGE = 900_000;
const MAX_OUTPUT = 2_000_000;
const MAX_CLIPBOARD_IMAGE = 10 * 1024 * 1024;

type Reply = {
	success: boolean;
	data: Record<string, unknown> | null;
	error?: { code: string; message: string; details?: string };
	target_receipt?: { pid: number; window_id?: number; process_start_identity_decimal?: string };
};

class NativeError extends Error {
	constructor(readonly code: string, message: string) {
		super(message);
	}
}

async function run(
	path: string,
	args: string[],
	signal: AbortSignal,
	errorJson = false,
	input?: string,
): Promise<string> {
	signal.throwIfAborted();
	try {
		const pending = exec(path, args, {
			encoding: "utf8",
			signal,
			killSignal: "SIGKILL",
			maxBuffer: MAX_OUTPUT,
		});
		let inputError: Error | undefined;
		if (input !== undefined) {
			// A signing or setup refusal can exit before reading stdin; its JSON still owns the outcome.
			pending.child.stdin!.on("error", (error) => inputError = error);
			pending.child.stdin!.end(input);
		}
		const { stdout } = await pending;
		if (inputError && !stdout.trim()) throw inputError;
		return stdout;
	} catch (error) {
		signal.throwIfAborted();
		const failed = error as Error & { code?: number | string; stdout?: string; stderr?: string };
		// The native client reports expected refusals as JSON on unsuccessful exits too.
		if (errorJson && typeof failed.code === "number" && failed.stdout?.trim()) return failed.stdout;
		throw new Error((failed.stderr?.trim() || failed.message).slice(0, 2000), { cause: error });
	}
}

const caller = (config: DesktopConfig): Native => async (args, signal, options = {}) => {
	const { client, socket } = config;
	if (!existsSync(client)) throw new Error(`The native desktop client is missing at ${client}.`);
	if (!existsSync(socket)) {
		throw new Error(`Open ${config.name ?? "the desktop host app"} on this host to enable native desktop tools.`);
	}
	signal.throwIfAborted();
	options.onDispatch?.();
	const output = await run(client, [socket, ...args], signal, true, options.input);
	let value: Reply;
	try {
		value = JSON.parse(output) as Reply;
	} catch {
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
			throw new Error(
				"Native inspection returned a different application or window. Refresh the desktop inventory and select the target again.",
			);
		}
	}
	return {
		...value.data,
		...(value.target_receipt ? { target_receipt: value.target_receipt } : {}),
	};
};

function bounded(data: Record<string, unknown>, field: string): string {
	const source = data[field];
	if (!Array.isArray(source)) throw new Error(`Native inspection returned no ${field} array.`);
	const values = [...source];
	const value = { ...data, [field]: values };
	let text = JSON.stringify(value);
	while (Buffer.byteLength(text) > MAX_TEXT && values.length) {
		values.pop();
		text = JSON.stringify({
			...value,
			ace_truncated: true,
			ace_omitted: source.length - values.length,
		});
	}
	if (Buffer.byteLength(text) > MAX_TEXT) {
		throw new Error("Native inspection metadata exceeds the result limit.");
	}
	return text;
}

function positive(value: number): string {
	if (!Number.isSafeInteger(value) || value < 1) {
		throw new Error("Choose a positive application PID and window ID from the desktop inventory.");
	}
	return String(value);
}

async function screenshot(input: string, output: string, signal: AbortSignal) {
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
		if ((await stat(output)).size > MAX_IMAGE) continue;
		const info = await run(
			"/usr/bin/sips",
			["-g", "pixelWidth", "-g", "pixelHeight", output],
			signal,
		);
		const width = Number(/pixelWidth:\s*(\d+)/.exec(info)?.[1]);
		const height = Number(/pixelHeight:\s*(\d+)/.exec(info)?.[1]);
		if (!width || !height) throw new Error("Could not read the screenshot dimensions.");
		const bytes = await readFile(output);
		if (bytes.length > MAX_IMAGE) {
			throw new Error("The resized screenshot exceeds the result limit.");
		}
		return { image: { mimeType: "image/jpeg", data: bytes.toString("base64") }, width, height };
	}
	throw new Error("The screenshot could not be resized within the result limit.");
}

function clipboardFiles(data: Record<string, unknown>): DesktopResult {
	const files = data.files;
	if (
		typeof data.present !== "boolean" || !Number.isSafeInteger(data.change_count)
		|| (data.present
			? !Array.isArray(files) || !files.length || files.length > 32
				|| files.some((file) =>
					!file || typeof file.url !== "string" || typeof file.path !== "string"
					|| !file.path.startsWith("/")
				)
			: files !== undefined)
	) throw new Error("The native clipboard file read returned an unsupported response.");
	const text = JSON.stringify(data);
	if (Buffer.byteLength(text) > 24_000) {
		throw new Error("Clipboard file references exceed the complete 24 KB result limit.");
	}
	return { text };
}

function clipboardImage(data: Record<string, unknown>): DesktopResult {
	if (typeof data.present !== "boolean" || !Number.isSafeInteger(data.change_count)) {
		throw new Error("The native clipboard image read returned an unsupported response.");
	}
	if (!data.present) {
		if (data.image !== undefined || data.source !== undefined) {
			throw new Error("An absent clipboard image returned unexpected image data.");
		}
		return { text: JSON.stringify(data) };
	}
	const preview = data.image as Record<string, unknown> | undefined;
	const source = data.source as Record<string, unknown> | undefined;
	if (
		!preview || !source || typeof preview.data !== "string"
		|| !["image/png", "image/jpeg"].includes(String(preview.mimeType))
		|| ![preview.width, preview.height].every((value) =>
			typeof value === "number" && Number.isSafeInteger(value) && value > 0 && value <= 1600
		)
		|| preview.data.length > Math.ceil(MAX_IMAGE / 3) * 4
	) throw new Error("The native clipboard image preview is missing or exceeds its limits.");
	const bytes = Buffer.from(preview.data, "base64");
	if (
		!bytes.length || bytes.length > MAX_IMAGE || bytes.length !== preview.bytes
		|| bytes.toString("base64") !== preview.data
	) throw new Error("The native clipboard image preview is not a complete bounded image.");
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
	return { text, image: { mimeType: preview.mimeType as string, data: encoded as string } };
}

async function inspect(
	native: Native,
	request: Extract<DesktopRequest, { op: "inspect" }>,
	signal: AbortSignal,
): Promise<DesktopResult> {
	const pid = positive(request.pid);
	const window = positive(request.window);
	const mode = request.mode ?? "accessibility";
	if (mode !== "accessibility" && mode !== "pixels") {
		throw new Error("Choose accessibility or pixels inspection mode.");
	}
	const directory = await mkdtemp(join(tmpdir(), "desktop-tools-"));
	try {
		const path = join(directory, "capture.png");
		const args = ["inspect", pid, window, path];
		if (mode === "pixels") args.push(mode);
		const data = await native(args, signal, { target: request });
		const { image, width, height } = await screenshot(path, join(directory, "image.jpg"), signal);
		const { screenshot_raw: _raw, screenshot_annotated: _annotated, ...observation } = data;
		const text = bounded({
			...observation,
			ace_image: {
				width,
				height,
				note:
					"Screenshot resized; Accessibility bounds remain in their original coordinate system. Pointer points use fractions of this image: x from the left edge and y from the top, each >= 0 and < 1.",
			},
		}, "ui_elements");
		return { text, image };
	} catch (error) {
		if (!(error instanceof NativeError)) throw error;
		return {
			isError: true,
			text: JSON.stringify({
				inspection_error: { code: error.code, message: error.message.slice(0, 4000) },
				requested_target: { pid: request.pid, window_id: request.window, mode },
				target_availability: await availability(native, request, signal),
				guidance:
					"This inspection dispatched no input and returned no observation snapshot. Availability was read after the failure and does not establish its cause. Refresh desktop_apps and desktop_windows if the target changed. Retry an incomplete Accessibility read once; pixels mode can inspect the same exact window without Accessibility, with point-only action authority. Native capture already retries a changed capture receipt once. Neither mode activates a window. Do not loop on an unavailable target or repeat an earlier action to recover an observation.",
			}),
		};
	} finally {
		await rm(directory, { recursive: true, force: true });
	}
}

function validatePoint(point: unknown) {
	if (!point || typeof point !== "object" || !("x" in point) || !("y" in point)) {
		throw new Error("Choose a normalized screenshot point with x and y coordinates.");
	}
	for (const value of [point.x, point.y]) {
		if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value >= 1) {
			throw new Error("Screenshot point coordinates must be at least 0 and less than 1.");
		}
	}
}

async function availability(
	native: Native,
	request: Extract<DesktopRequest, { op: "inspect" }>,
	signal: AbortSignal,
): Promise<Record<string, unknown>> {
	if (signal.aborted) return { error: "The desktop call ended before availability could be read." };
	const deadline = new AbortController();
	const timer = setTimeout(() => deadline.abort(), 2500);
	try {
		const context = AbortSignal.any([signal, deadline.signal]);
		const results = await Promise.allSettled([
			native(["apps"], context),
			native(["windows", String(request.pid)], context),
		]);
		const result: Record<string, unknown> = { observed_at: new Date().toISOString() };
		for (
			const [index, field, key, id, fields] of [
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
			] as const
		) {
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
	} finally {
		clearTimeout(timer);
	}
}

function validateApplication(application: DesktopApplication) {
	if (!application || typeof application !== "object" || Object.keys(application).length !== 1) {
		throw new Error("Use exactly one application path or bundle_id.");
	}
	if ("path" in application) {
		const path = application.path;
		if (
			typeof path !== "string" || path.length > 4096 || !path.startsWith("/")
			|| !path.toLowerCase().endsWith(".app") || path.includes("\0")
		) throw new Error("Use an absolute .app path for launch.");
	} else if (
		!("bundle_id" in application) || typeof application.bundle_id !== "string"
		|| application.bundle_id.length > 256
		|| !/^[A-Za-z0-9.-]+$/.test(application.bundle_id)
	) throw new Error("Use an exact application bundle ID for launch.");
}

function validateAction(request: DesktopAction) {
	if (request.op === "launch") {
		if (Object.keys(request).some((key) => !["op", "application"].includes(key))) {
			throw new Error("Launch accepts exactly one application path or bundle_id.");
		}
		validateApplication(request.application);
		return;
	}
	if (request.op === "open") {
		const item = request.item;
		if (
			Object.keys(request).some((key) => !["op", "item", "application"].includes(key))
			|| !item || typeof item !== "object" || Object.keys(item).length !== 1
		) throw new Error("Open accepts exactly one item path or url and an optional application.");
		if ("path" in item) {
			if (
				typeof item.path !== "string" || item.path.length > 4096
				|| !item.path.startsWith("/") || item.path.includes("\0")
			) throw new Error("Use an existing absolute item path.");
		} else if (
			!("url" in item) || typeof item.url !== "string" || item.url.length > 4096
			|| !/^[A-Za-z][A-Za-z0-9+.-]*:/.test(item.url)
			|| /\p{Cc}/u.test(item.url)
		) {
			throw new Error(
				"Use a complete absolute URL with an explicit scheme and no control characters.",
			);
		}
		if (request.application !== undefined) validateApplication(request.application);
		if (Buffer.byteLength(JSON.stringify(request)) > 16_384) {
			throw new Error("The open request exceeds 16 KiB.");
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
	if (isDesktopManagement(request)) return validateManagement(request);
	if (request.op === "clipboard-write") {
		if ("format" in request) {
			if (request.format === "files") {
				if (
					"text" in request || "path" in request || !Array.isArray(request.paths)
					|| !request.paths.length || request.paths.length > 32
					|| request.paths.some((path) =>
						typeof path !== "string" || !path.startsWith("/") || path.length > 4096
						|| path.includes("\0")
					)
				) throw new Error("Use format files with 1–32 absolute paths and no text or image path.");
				return;
			}
			if (
				request.format !== "image" || "text" in request || "paths" in request
				|| typeof request.path !== "string"
				|| !request.path.startsWith("/") || request.path.length > 4096
				|| request.path.includes("\0")
			) throw new Error("Use format image with one absolute image path and no text.");
			return;
		}
		if (
			"path" in request || "paths" in request || typeof request.text !== "string"
			|| request.text.length > 8192
		) {
			throw new Error("Clipboard text must contain at most 8192 UTF-16 code units.");
		}
		return;
	}
	if (typeof request.snapshot !== "string" || !request.snapshot || request.snapshot.length > 256) {
		throw new Error("Use the snapshot_id from a fresh desktop_inspect result.");
	}
	if (request.op === "drag") {
		validatePoint(request.from);
		validatePoint(request.to);
		if (request.from.x === request.to.x && request.from.y === request.to.y) {
			throw new Error("Choose distinct start and end points for a drag.");
		}
		if (request.button !== undefined && !DESKTOP_BUTTONS.includes(request.button)) {
			throw new Error("Choose the left or right mouse button for a drag.");
		}
		if (
			request.duration_ms !== undefined
			&& (!Number.isInteger(request.duration_ms) || request.duration_ms < 1
				|| request.duration_ms > 10000)
		) {
			throw new Error("Drag duration must be 1 to 10000 milliseconds.");
		}
		return;
	}
	if (request.op === "click" || request.op === "scroll") {
		if ((request.element === undefined) === (request.point === undefined)) {
			throw new Error("Choose exactly one observed element ID or normalized screenshot point.");
		}
		if (request.point !== undefined) validatePoint(request.point);
		else if (
			typeof request.element !== "string" || !request.element || request.element.length > 256
		) {
			throw new Error("Choose an element ID from the inspected snapshot.");
		}
		if (request.op === "click") {
			if (request.kind !== undefined && !DESKTOP_CLICKS.includes(request.kind)) {
				throw new Error("Choose single, double, right, middle, or triple click.");
			}
		} else if (
			!DESKTOP_DIRECTIONS.includes(request.direction) || !Number.isInteger(request.amount)
			|| request.amount < 1 || request.amount > 20
		) {
			throw new Error("Choose up, down, left, or right and 1 to 20 native scroll units.");
		}
		return;
	}
	if (request.op === "key") {
		if (!DESKTOP_KEYS.includes(request.key)) throw new Error("Choose one supported key.");
		const modifiers = request.modifiers;
		if (
			modifiers !== undefined && (
				!Array.isArray(modifiers) || modifiers.length > 4
				|| new Set(modifiers).size !== modifiers.length
				|| modifiers.some((modifier) => !DESKTOP_MODIFIERS.includes(modifier))
			)
		) {
			throw new Error("Use each of command, control, option, and shift at most once.");
		}
		return;
	}
	if (request.op === "insert") {
		if (typeof request.text !== "string" || !request.text || request.text.length > 8192) {
			throw new Error("Inserted text must contain 1 to 8192 UTF-16 code units.");
		}
		return;
	}
	if (typeof request.element !== "string" || !request.element || request.element.length > 256) {
		throw new Error("Choose an element ID from the inspected snapshot.");
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

function validateMenuPath(path: unknown) {
	if (
		!Array.isArray(path) || !path.length || path.length > 8
		|| path.some((title) => typeof title !== "string" || !title.trim() || title.length > 512)
	) {
		throw new Error(
			"Menu path requires 1 to 8 nonblank literal titles of at most 512 UTF-16 code units each.",
		);
	}
}

function validateAppTarget(target: DesktopAppTarget) {
	if (
		!target || typeof target !== "object" || !Number.isInteger(target.pid)
		|| target.pid < 1 || target.pid > 2_147_483_647
		|| typeof target.process_start_identity_decimal !== "string"
		|| !/^[1-9][0-9]{0,19}$/.test(target.process_start_identity_decimal)
		|| BigInt(target.process_start_identity_decimal) > 18_446_744_073_709_551_615n
	) throw new Error("Pass the application's target object from fresh desktop inventory unchanged.");
}

function validateAppOnly(target: DesktopAppTarget) {
	validateAppTarget(target);
	if (Object.keys(target).some((key) => !["pid", "process_start_identity_decimal"].includes(key))) {
		throw new Error("Pass only the application's target object from desktop_apps.");
	}
}

function validateManagement(request: DesktopManagement) {
	const target = request.target;
	if (request.op === "activate" || request.op === "quit") {
		validateAppOnly(target);
		return;
	}
	validateAppTarget(target);
	const window = request.target;
	if (
		!Number.isInteger(window.window_id) || window.window_id < 1 || window.window_id > 4_294_967_295
		|| typeof window.is_minimized !== "boolean" || !window.bounds
		|| ![window.bounds.x, window.bounds.y, window.bounds.width, window.bounds.height].every(
			Number.isFinite,
		)
		|| window.bounds.width <= 0 || window.bounds.height <= 0
	) {
		throw new Error(
			"Pass the window's target object, including its original bounds, from desktop_windows unchanged.",
		);
	}
	if (request.op === "move") {
		const position = request.position;
		if (!position || ![position.x, position.y].every(Number.isFinite)) {
			throw new Error("Window position must contain finite x and y in desktop logical points.");
		}
	}
	if (request.op === "resize") {
		const size = request.size;
		if (
			!size || ![size.width, size.height].every(Number.isFinite) || size.width <= 0
			|| size.height <= 0
		) {
			throw new Error(
				"Window size must contain positive finite width and height in desktop logical points.",
			);
		}
	}
}

function actionResult(data: Record<string, unknown>, outcome: DesktopOutcome): DesktopResult {
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
			},
			warning: "Native action metadata exceeded the result limit. Inspect the current state.",
		});
	}
	return { text, outcome, isError: outcome !== "completed" };
}

async function clipboardImageInput(path: string, signal: AbortSignal): Promise<string> {
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
			if (!read.bytesRead) break;
			size += read.bytesRead;
		}
		const after = await file.stat({ bigint: true });
		signal.throwIfAborted();
		if (
			size !== Number(before.size) || after.size !== before.size
			|| after.mtimeNs !== before.mtimeNs || after.ctimeNs !== before.ctimeNs
		) {
			throw new Error(
				"The image file changed while being read; choose a stable file before writing.",
			);
		}
		return bytes.subarray(0, size).toString("base64");
	} finally {
		await file.close();
	}
}

async function act(
	native: Native,
	request: DesktopAction,
	signal: AbortSignal,
): Promise<DesktopResult> {
	let dispatched = false;
	let data: Record<string, unknown>;
	try {
		validateAction(request);
		if (request.op === "clipboard-write" && "format" in request && request.format === "files") {
			for (const path of request.paths) {
				signal.throwIfAborted();
				const entry = await lstat(path);
				if (!entry.isFile() && !entry.isDirectory() && !entry.isSymbolicLink()) {
					throw new Error(
						"Clipboard file references require existing files, directories, or symbolic links.",
					);
				}
			}
			signal.throwIfAborted();
		}
		const input =
			request.op === "clipboard-write" && "format" in request && request.format === "image"
				? {
					op: request.op,
					format: request.format,
					image: await clipboardImageInput(request.path, signal),
				}
				: request;
		const operation = request.op === "menu"
			? "menu"
			: request.op === "clipboard-write"
			? "clipboard"
			: request.op === "launch"
			? "launch"
			: request.op === "open"
			? "open"
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
	} catch (error) {
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
	const outcome = data.outcome as DesktopOutcome;
	if (request.op === "menu") {
		const receipt = data.target_receipt as Reply["target_receipt"];
		if (
			(outcome === "completed" || receipt) && (!receipt || receipt.window_id !== undefined
				|| receipt.pid !== request.target.pid
				|| receipt.process_start_identity_decimal !== request.target.process_start_identity_decimal)
		) {
			return actionResult({
				...data,
				outcome: "unknown",
				receipt_error:
					"The menu command returned a different application receipt. Observe the intended app before any further action.",
			}, "unknown");
		}
		return actionResult(data, outcome);
	}

	if (
		outcome === "unknown"
		&& ((request.op === "quit" && data.terminated === false)
			|| (request.op === "close" && data.target_receipt))
	) {
		return await observeManagement(native, request, data, signal);
	}
	if (outcome !== "completed" || request.op === "clipboard-write") {
		return actionResult(data, outcome);
	}
	if (isDesktopManagement(request) || request.op === "launch" || request.op === "open") {
		return await observeManagement(native, request, data, signal);
	}
	// Observation is separate from delivery: its failure must not turn completed input into a retry.
	try {
		const receipt = data.target_receipt as Reply["target_receipt"];
		if (!receipt?.process_start_identity_decimal || !receipt.window_id) {
			throw new Error("No exact-window action receipt.");
		}
		const observation = await inspect(native, {
			op: "inspect",
			pid: receipt.pid,
			window: receipt.window_id,
		}, signal);
		const fresh = JSON.parse(observation.text) as Record<string, unknown>;
		if (observation.isError) {
			return actionResult({
				...data,
				observation_error: fresh,
				message:
					"The action completed, but a fresh observation was unavailable. Inspect again to verify the result; do not repeat the action blindly.",
			}, outcome);
		}
		const current = fresh.target_receipt as Reply["target_receipt"];
		if (current?.process_start_identity_decimal !== receipt.process_start_identity_decimal) {
			throw new Error("The target application changed after the action.");
		}
		return {
			text: bounded({ ...fresh, action: data }, "ui_elements"),
			image: observation.image,
			outcome,
			isError: false,
		};
	} catch (error) {
		return actionResult({
			...data,
			observation_error: (error instanceof Error ? error.message : String(error)).slice(0, 2000),
			message:
				"The action completed, but a fresh observation was unavailable. Inspect again to verify the result; do not repeat the action blindly.",
		}, outcome);
	}
}

async function observeManagement(
	native: Native,
	request: DesktopManagement | DesktopLaunch | DesktopOpen,
	action: Record<string, unknown>,
	signal: AbortSignal,
): Promise<DesktopResult> {
	const data: Record<string, unknown> = { action };
	const outcome = action.outcome === "unknown" ? "unknown" : "completed";
	const receipt = action.target_receipt as Reply["target_receipt"];
	const target = request.op === "launch" || request.op === "open"
		? (action.application as { target?: DesktopAppTarget } | undefined)?.target
		: request.target;
	if (
		!receipt || !target || receipt.pid !== target.pid
		|| receipt.process_start_identity_decimal !== target.process_start_identity_decimal
		|| (request.op === "activate" || request.op === "quit" || request.op === "launch"
				|| request.op === "open"
			? receipt.window_id !== undefined
			: receipt.window_id !== request.target.window_id)
	) {
		return actionResult({
			...action,
			outcome: "unknown",
			reason:
				"The native action returned a different target receipt. Refresh the target before any retry.",
		}, "unknown");
	}
	try {
		const apps = await native(["apps"], signal);
		if (!Array.isArray(apps.apps)) throw new Error("Native application inventory is unavailable.");
		data.application_inventory_completeness = apps.inventory_completeness;
		data.application_inventory_warnings = apps.inventory_warnings;
		const app = apps.apps.find((app) => app.pid === receipt.pid);
		data.application = app || null;
		// The native receipt owns close/quit evidence; later inventory cannot undo or establish it.
		if (!app && (request.op === "quit" || request.op === "close")) {
			return managementResult(data, action, outcome);
		}
		if (!app) throw new Error("The target application was not returned by the later inventory.");
		if (app.process_start_identity_decimal !== receipt.process_start_identity_decimal) {
			throw new Error("The application changed process generation after the action.");
		}
		const windows = await native(["windows", String(receipt.pid)], signal);
		if (!Array.isArray(windows.windows)) throw new Error("Native window inventory is unavailable.");
		data.window_inventory_completeness = windows.inventory_completeness;
		data.window_inventory_warnings = windows.inventory_warnings;
		data.windows = windows.windows;
		if (
			windows.windows.some((window) =>
				window.process_start_identity_decimal !== receipt.process_start_identity_decimal
			)
		) {
			throw new Error(
				"Later window inventory could not be bound to the original application generation.",
			);
		}
		if (
			request.op === "activate" || request.op === "quit" || request.op === "launch"
			|| request.op === "open"
			|| request.op === "close"
		) {
			return managementResult(data, action, outcome);
		}
		if (!windows.windows.some((window) => window.window_id === receipt.window_id)) {
			throw new Error("The exact window was not returned by the later inventory.");
		}
		// Minimization intentionally removes the visible capture target; refreshed inventory owns its state.
		if (request.op === "minimize") return managementResult(data, action);
		const observation = await inspect(native, {
			op: "inspect",
			pid: receipt.pid,
			window: receipt.window_id!,
		}, signal);
		const fresh = JSON.parse(observation.text) as Record<string, unknown>;
		if (observation.isError) {
			data.observation_error = fresh;
			data.message =
				"The native action completed. Later inventory or inspection was unavailable; refresh the target before any further action, without repeating the completed action blindly.";
			return managementResult(data, action);
		}
		const current = fresh.target_receipt as Reply["target_receipt"];
		if (current?.process_start_identity_decimal !== receipt.process_start_identity_decimal) {
			throw new Error("The application changed process generation before the later inspection.");
		}
		return {
			text: bounded({ ...data, ...fresh }, "ui_elements"),
			image: observation.image,
			outcome: "completed",
			isError: false,
		};
	} catch (error) {
		data.observation_error = (error instanceof Error ? error.message : String(error)).slice(
			0,
			2000,
		);
		data.message = outcome === "completed"
			? "The native action completed. Later inventory or inspection was unavailable; refresh the target before any further action, without repeating the completed action blindly."
			: "Native completion was not confirmed and later inventory was unavailable. Refresh the target before choosing any further action; do not blindly repeat the request.";
		return managementResult(data, action, outcome);
	}
}

function managementResult(
	data: Record<string, unknown>,
	action: Record<string, unknown>,
	outcome: "completed" | "unknown" = "completed",
): DesktopResult {
	try {
		const text = Array.isArray(data.windows) ? bounded(data, "windows") : JSON.stringify(data);
		if (Buffer.byteLength(text) > MAX_TEXT) {
			throw new Error("The later inventory exceeds the result limit.");
		}
		return { text, outcome, isError: outcome !== "completed" };
	} catch {
		return actionResult({
			...action,
			observation_error: data.observation_error || "The later inventory exceeds the result limit.",
			message:
				"The native action outcome is preserved. Later inventory was omitted to fit the result limit; refresh the target without blindly repeating the action.",
		}, outcome);
	}
}

/** Creates a client bound to one host socket and signed client; calls are independent processes. */
export function createDesktop(config: DesktopConfig): DesktopClient {
	const native = caller(config);
	return async (request, signal) => {
		const result = await execute(native, request, signal);
		return { ...result, data: JSON.parse(result.text) as unknown };
	};
}

async function execute(
	native: Native,
	request: DesktopRequest,
	abort?: AbortSignal,
): Promise<DesktopResult> {
	if (
		!request
		|| ![
			"clipboard-read",
			"clipboard-write",
			"apps",
			"windows",
			"menus",
			"menu",
			"inspect",
			"click",
			"type",
			"key",
			"insert",
			"select",
			"scroll",
			"drag",
			"activate",
			"launch",
			"open",
			"quit",
			"close",
			"focus",
			"minimize",
			"restore",
			"move",
			"resize",
		].includes(
			request.op,
		)
	) {
		throw new Error("Unknown native desktop request.");
	}
	if (process.platform !== "darwin") {
		const reason = "Native desktop tools require macOS 15 or later.";
		if (isDesktopAction(request)) return actionResult({ outcome: "refused", reason }, "refused");
		throw new Error(reason);
	}
	const deadline = new AbortController();
	const timer = setTimeout(
		() => deadline.abort(new Error("Native desktop operation timed out after 30 seconds.")),
		30_000,
	);
	const signal = abort ? AbortSignal.any([abort, deadline.signal]) : deadline.signal;
	try {
		if (isDesktopAction(request)) return await act(native, request, signal);
		if (request.op === "inspect") return await inspect(native, request, signal);
		if (request.op === "menus") {
			validateAppOnly(request.target);
			if (request.path !== undefined) validateMenuPath(request.path);
			const input = JSON.stringify(request);
			if (Buffer.byteLength(input) > 4096) {
				throw new Error("Menu request exceeds the 4096-byte limit.");
			}
			const data = await native(["menus"], signal, { input });
			const target = data.target as DesktopAppTarget | undefined;
			if (
				target?.pid !== request.target.pid
				|| target.process_start_identity_decimal !== request.target.process_start_identity_decimal
			) throw new Error("Native menu inventory returned a different application generation.");
			if (request.path !== undefined) {
				// An older client must not turn a scoped read into full menu disclosure.
				const path = request.path, filter = data.filter as { path?: unknown } | undefined;
				if (
					!Array.isArray(filter?.path) || filter.path.length !== path.length
					|| filter.path.some((title, index) => title !== path[index])
					|| !Array.isArray(data.menus) || data.menus.some((row) =>
						!Array.isArray(row?.path) || path.some((title, index) =>
							row.path[index] !== title
						)
					)
				) throw new Error("Native menu inventory did not honor the requested literal path.");
			}
			return { text: bounded(data, "menus") };
		}
		if (request.op === "clipboard-read") {
			if (
				request.format !== undefined && request.format !== "text" && request.format !== "image"
				&& request.format !== "files"
			) {
				throw new Error("Choose text, image, or files clipboard format.");
			}
			const data = await native(["clipboard"], signal, { input: JSON.stringify(request) });
			if (request.format === "image") return clipboardImage(data);
			if (request.format === "files") return clipboardFiles(data);
			if (
				typeof data.present !== "boolean" || !Number.isSafeInteger(data.change_count)
				|| (data.present ? typeof data.text !== "string" : data.text !== undefined)
			) throw new Error("The native clipboard read returned an unsupported response.");
			const text = JSON.stringify(data);
			if (Buffer.byteLength(text) > 24_000) {
				throw new Error("Clipboard text exceeds the complete 24 KB result limit.");
			}
			return { text };
		}
		let query: string | undefined;
		if (request.op === "apps" && request.query !== undefined) {
			if (
				typeof request.query !== "string" || request.query.length > 256
				|| !request.query.trim()
			) {
				throw new Error(
					"Application query must contain non-whitespace text and at most 256 characters.",
				);
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
			const matches = apps.filter((app) =>
				app.name.toLowerCase().includes(search) || app.bundle_id?.toLowerCase().includes(search)
			);
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
	} finally {
		clearTimeout(timer);
	}
}
