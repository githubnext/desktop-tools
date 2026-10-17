import { constants } from "node:fs";
import { copyFile, lstat, open, stat } from "node:fs/promises";
import { dirname, isAbsolute, normalize } from "node:path";

/** A rectangle in global top-left desktop points, as window and display bounds use. */
export type DesktopRegion = { x: number; y: number; width: number; height: number };
type CaptureSave = { save_path?: unknown; overwrite?: unknown; region?: unknown };
type SavedCapture = { path: string; width: number; height: number; region: DesktopRegion | null };

type Run = (file: string, args: string[], signal: AbortSignal) => Promise<string>;
type Dimensions = (path: string, signal: AbortSignal) => Promise<{ width: number; height: number }>;

/** File extensions a clipboard image may be saved with, by its type. */
const CLIPBOARD_EXTENSIONS: Record<string, string[]> = {
	"public.png": ["png"],
	"public.jpeg": ["jpg", "jpeg"],
	"public.tiff": ["tif", "tiff"],
};

/** Checks save_path, overwrite and region before anything is captured. */
export async function validateSave(
	request: CaptureSave,
	extensions: string[] = ["png"],
): Promise<string | undefined> {
	const { save_path: path, overwrite, region } = request;
	if (overwrite !== undefined && typeof overwrite !== "boolean") throw new Error("Choose overwrite true or false.");
	if (path === undefined) {
		if (overwrite !== undefined || region !== undefined) {
			throw new Error("overwrite and region apply to the saved file; pass save_path too.");
		}
		return undefined;
	}
	if (
		typeof path !== "string" || !isAbsolute(path) || normalize(path) !== path || path.length > 1024
		|| path.includes("\0") || !extensions.includes(extensionOf(path))
	) {
		const names = extensions.map((extension) => "." + extension);
		throw new Error(
			`save_path must be a normalized absolute path ending in ${
				names.length > 1 ? names.slice(0, -1).join(", ") + " or " + names.at(-1) : names[0]
			}.`,
		);
	}
	if (region !== undefined) regionOf(region);
	const parent = await stat(dirname(path)).catch(() => undefined);
	if (!parent?.isDirectory()) throw new Error("save_path's folder must already exist.");
	const existing = await lstat(path).catch(() => undefined);
	if (existing) {
		if (!existing.isFile()) throw new Error("save_path names something other than a regular file; nothing was written.");
		if (overwrite !== true) {
			throw new Error("save_path already exists; pass overwrite true to replace it. Nothing was captured.");
		}
	}
	return path;
}

function regionOf(value: unknown): DesktopRegion {
	const region = value as DesktopRegion;
	if (
		!region || typeof region !== "object" || Object.keys(region).length !== 4
		|| ![region.x, region.y, region.width, region.height].every((part) => typeof part === "number" && Number.isFinite(part))
		|| region.width <= 0 || region.height <= 0
	) {
		throw new Error("region must be x, y, width and height in global desktop points, with positive size.");
	}
	return region;
}

/**
 * Writes the full-resolution capture, or the part of it under region, as a PNG at path. area is the capture's
 * extent in global desktop points; the capture's own pixels map onto it, so nothing is scaled.
 */
export async function saveCapture(
	capture: string,
	scratch: string,
	path: string,
	request: CaptureSave,
	area: DesktopRegion | undefined,
	tools: { run: Run; dimensions: Dimensions },
	signal: AbortSignal,
): Promise<SavedCapture> {
	const size = await tools.dimensions(capture, signal);
	let source = capture;
	let region: DesktopRegion | null = null;
	if (request.region !== undefined) {
		region = regionOf(request.region);
		if (!area || area.width <= 0 || area.height <= 0) {
			throw new Error("This capture reported no desktop bounds, so a region can't be located in it.");
		}
		// Half a point of slack absorbs rounding in reported bounds; the crop still stays inside the image.
		const slack = 0.5;
		if (
			region.x < area.x - slack || region.y < area.y - slack
			|| region.x + region.width > area.x + area.width + slack
			|| region.y + region.height > area.y + area.height + slack
		) {
			throw new Error(
				`region must lie inside the captured area, x ${area.x}, y ${area.y}, width ${area.width}, height ${area.height} in desktop points.`,
			);
		}
		const scaleX = size.width / area.width;
		const scaleY = size.height / area.height;
		const left = Math.max(0, Math.round((region.x - area.x) * scaleX));
		const top = Math.max(0, Math.round((region.y - area.y) * scaleY));
		const width = Math.min(size.width - left, Math.round(region.width * scaleX));
		const height = Math.min(size.height - top, Math.round(region.height * scaleY));
		if (width < 1 || height < 1) throw new Error("region covers less than one pixel of the capture.");
		source = `${scratch}/region.png`;
		await tools.run("/usr/bin/sips", [
			"-s", "format", "png",
			"--cropOffset", String(top), String(left),
			"-c", String(height), String(width),
			capture, "--out", source,
		], signal);
	} else if (!(await isPng(capture))) {
		source = `${scratch}/full.png`;
		await tools.run("/usr/bin/sips", ["-s", "format", "png", capture, "--out", source], signal);
	}
	const saved = await tools.dimensions(source, signal);
	signal.throwIfAborted();
	await place(source, path, request.overwrite === true);
	return { path, width: saved.width, height: saved.height, region };
}

export const CLIPBOARD_SAVE_EXTENSIONS = Object.values(CLIPBOARD_EXTENSIONS).flat();
type SavedClipboardImage = { path: string; uti: string; mime_type: string; bytes: number; width: number; height: number };

/**
 * Saves the clipboard image's original bytes, exported to a private file, at path. The bytes are copied
 * unchanged, so path's extension must name the image's own type.
 */
export async function saveClipboardImage(
	exported: string,
	path: string,
	overwrite: boolean,
	source: { uti: string; mimeType: string; bytes: number; width: number; height: number },
	signal: AbortSignal,
): Promise<SavedClipboardImage> {
	const extensions = CLIPBOARD_EXTENSIONS[source.uti];
	if (!extensions) throw new Error(`The clipboard image type ${source.uti} can't be saved.`);
	if (!extensions.includes(extensionOf(path))) {
		throw new Error(
			`The clipboard holds a ${source.mimeType} image; save it with a .${extensions.join(" or .")} path. Nothing was written.`,
		);
	}
	const exportedFile = await lstat(exported);
	if (!exportedFile.isFile() || exportedFile.size !== source.bytes) {
		throw new Error("The exported clipboard image is incomplete. Nothing was written.");
	}
	signal.throwIfAborted();
	await place(exported, path, overwrite);
	return { path, uti: source.uti, mime_type: source.mimeType, bytes: source.bytes, width: source.width, height: source.height };
}

function extensionOf(path: string): string {
	return path.split(".").at(-1)!.toLowerCase();
}

/** Copies a finished file to save_path; exclusive unless overwrite was asked for, so a file created since validation is never replaced. */
async function place(source: string, path: string, overwrite: boolean): Promise<void> {
	await copyFile(source, path, overwrite ? 0 : constants.COPYFILE_EXCL);
}

async function isPng(path: string): Promise<boolean> {
	const file = await open(path, "r");
	try {
		const head = Buffer.alloc(8);
		await file.read(head, 0, 8, 0);
		return head.equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
	} finally {
		await file.close();
	}
}
