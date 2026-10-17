import { constants } from "node:fs";
import { copyFile, lstat, open, stat } from "node:fs/promises";
import { dirname, isAbsolute, normalize } from "node:path";
/** Checks save_path, overwrite and region before anything is captured. */
export async function validateSave(request) {
    const { save_path: path, overwrite, region } = request;
    if (overwrite !== undefined && typeof overwrite !== "boolean")
        throw new Error("Choose overwrite true or false.");
    if (path === undefined) {
        if (overwrite !== undefined || region !== undefined) {
            throw new Error("overwrite and region apply to the saved file; pass save_path too.");
        }
        return undefined;
    }
    if (typeof path !== "string" || !isAbsolute(path) || normalize(path) !== path || path.length > 1024
        || path.includes("\0") || !/\.png$/i.test(path)) {
        throw new Error("save_path must be a normalized absolute path ending in .png.");
    }
    if (region !== undefined)
        regionOf(region);
    const parent = await stat(dirname(path)).catch(() => undefined);
    if (!parent?.isDirectory())
        throw new Error("save_path's folder must already exist.");
    const existing = await lstat(path).catch(() => undefined);
    if (existing) {
        if (!existing.isFile())
            throw new Error("save_path names something other than a regular file; nothing was written.");
        if (overwrite !== true) {
            throw new Error("save_path already exists; pass overwrite true to replace it. Nothing was captured.");
        }
    }
    return path;
}
function regionOf(value) {
    const region = value;
    if (!region || typeof region !== "object" || Object.keys(region).length !== 4
        || ![region.x, region.y, region.width, region.height].every((part) => typeof part === "number" && Number.isFinite(part))
        || region.width <= 0 || region.height <= 0) {
        throw new Error("region must be x, y, width and height in global desktop points, with positive size.");
    }
    return region;
}
/**
 * Writes the full-resolution capture, or the part of it under region, as a PNG at path. area is the capture's
 * extent in global desktop points; the capture's own pixels map onto it, so nothing is scaled.
 */
export async function saveCapture(capture, scratch, path, request, area, tools, signal) {
    const size = await tools.dimensions(capture, signal);
    let source = capture;
    let region = null;
    if (request.region !== undefined) {
        region = regionOf(request.region);
        if (!area || area.width <= 0 || area.height <= 0) {
            throw new Error("This capture reported no desktop bounds, so a region can't be located in it.");
        }
        // Half a point of slack absorbs rounding in reported bounds; the crop still stays inside the image.
        const slack = 0.5;
        if (region.x < area.x - slack || region.y < area.y - slack
            || region.x + region.width > area.x + area.width + slack
            || region.y + region.height > area.y + area.height + slack) {
            throw new Error(`region must lie inside the captured area, x ${area.x}, y ${area.y}, width ${area.width}, height ${area.height} in desktop points.`);
        }
        const scaleX = size.width / area.width;
        const scaleY = size.height / area.height;
        const left = Math.max(0, Math.round((region.x - area.x) * scaleX));
        const top = Math.max(0, Math.round((region.y - area.y) * scaleY));
        const width = Math.min(size.width - left, Math.round(region.width * scaleX));
        const height = Math.min(size.height - top, Math.round(region.height * scaleY));
        if (width < 1 || height < 1)
            throw new Error("region covers less than one pixel of the capture.");
        source = `${scratch}/region.png`;
        await tools.run("/usr/bin/sips", [
            "-s", "format", "png",
            "--cropOffset", String(top), String(left),
            "-c", String(height), String(width),
            capture, "--out", source,
        ], signal);
    }
    else if (!(await isPng(capture))) {
        source = `${scratch}/full.png`;
        await tools.run("/usr/bin/sips", ["-s", "format", "png", capture, "--out", source], signal);
    }
    const saved = await tools.dimensions(source, signal);
    signal.throwIfAborted();
    // Exclusive unless overwrite was asked for, so a file created since validation is never replaced.
    await copyFile(source, path, request.overwrite === true ? 0 : constants.COPYFILE_EXCL);
    return { path, width: saved.width, height: saved.height, region };
}
async function isPng(path) {
    const file = await open(path, "r");
    try {
        const head = Buffer.alloc(8);
        await file.read(head, 0, 8, 0);
        return head.equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
    }
    finally {
        await file.close();
    }
}
