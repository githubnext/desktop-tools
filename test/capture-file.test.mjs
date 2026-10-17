import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { promisify } from "node:util";
import { CLIPBOARD_SAVE_EXTENSIONS, saveCapture, saveClipboardImage, validateSave } from "../dist/capture-file.js";

const exec = promisify(execFile);
const tools = {
	run: async (file, args) => (await exec(file, args)).stdout,
	dimensions: async (path) => {
		const { stdout } = await exec("/usr/bin/sips", ["-g", "pixelWidth", "-g", "pixelHeight", path]);
		return { width: Number(/pixelWidth:\s*(\d+)/.exec(stdout)[1]), height: Number(/pixelHeight:\s*(\d+)/.exec(stdout)[1]) };
	},
};
const signal = new AbortController().signal;
// sips ships with macOS; elsewhere these tests have nothing to run.
const skip = !existsSync("/usr/bin/sips") && "needs macOS sips";

/** A 200 × 100 pixel 24-bit BMP whose left half is red and right half blue. */
function bitmap() {
	const width = 200, height = 100, row = width * 3, size = 54 + row * height;
	const bytes = Buffer.alloc(size);
	bytes.write("BM", 0, "latin1");
	bytes.writeUInt32LE(size, 2);
	bytes.writeUInt32LE(54, 10);
	bytes.writeUInt32LE(40, 14);
	bytes.writeInt32LE(width, 18);
	bytes.writeInt32LE(height, 22);
	bytes.writeUInt16LE(1, 26);
	bytes.writeUInt16LE(24, 28);
	for (let y = 0; y < height; y++) {
		for (let x = 0; x < width; x++) {
			const at = 54 + y * row + x * 3;
			bytes[at + (x < width / 2 ? 2 : 0)] = 255;
		}
	}
	return bytes;
}

async function fixture() {
	const directory = await mkdtemp(join(tmpdir(), "capture-file-"));
	const capture = join(directory, "capture.png");
	await writeFile(join(directory, "capture.bmp"), bitmap());
	await exec("/usr/bin/sips", ["-s", "format", "png", join(directory, "capture.bmp"), "--out", capture]);
	return { directory, capture };
}

const isPng = (bytes) => bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));

test("save options are checked before capture", { skip }, async (t) => {
	const { directory } = await fixture();
	t.after(() => rm(directory, { recursive: true, force: true }));
	assert.equal(await validateSave({}), undefined);
	await assert.rejects(validateSave({ overwrite: true }), /pass save_path/);
	await assert.rejects(validateSave({ region: { x: 0, y: 0, width: 1, height: 1 } }), /pass save_path/);
	for (const path of ["relative.png", "/tmp/shot.jpg", "/tmp/../tmp/shot.png", 7]) {
		await assert.rejects(validateSave({ save_path: path }), /absolute path ending in \.png/);
	}
	await assert.rejects(validateSave({ save_path: join(directory, "missing", "a.png") }), /folder must already exist/);
	await assert.rejects(
		validateSave({ save_path: join(directory, "a.png"), region: { x: 0, y: 0, width: 0, height: 1 } }),
		/positive size/,
	);
	await assert.rejects(validateSave({ save_path: join(directory, "capture.png") }), /already exists; pass overwrite/);
	assert.equal(await validateSave({ save_path: join(directory, "capture.png"), overwrite: true }), join(directory, "capture.png"));
	await symlink(join(directory, "capture.png"), join(directory, "link.png"));
	await assert.rejects(validateSave({ save_path: join(directory, "link.png"), overwrite: true }), /other than a regular file/);
	assert.equal(await validateSave({ save_path: join(directory, "new.png") }), join(directory, "new.png"));
});

test("the whole capture is written at full resolution", { skip }, async (t) => {
	const { directory, capture } = await fixture();
	t.after(() => rm(directory, { recursive: true, force: true }));
	const path = join(directory, "out.png");
	const saved = await saveCapture(capture, directory, path, { save_path: path }, undefined, tools, signal);
	assert.deepEqual(saved, { path, width: 200, height: 100, region: null });
	assert.deepEqual(await readFile(path), await readFile(capture));
});

test("a region in points is cropped at the capture's pixel scale", { skip }, async (t) => {
	const { directory, capture } = await fixture();
	t.after(() => rm(directory, { recursive: true, force: true }));
	const path = join(directory, "right.png");
	// The 200 × 100 pixel capture covers 100 × 50 points at x 1000, y 20: two pixels per point.
	const area = { x: 1000, y: 20, width: 100, height: 50 };
	const region = { x: 1050, y: 30, width: 50, height: 20 };
	const saved = await saveCapture(capture, directory, path, { save_path: path, region }, area, tools, signal);
	assert.deepEqual(saved, { path, width: 100, height: 40, region });
	assert.ok(isPng(await readFile(path)));
	// Only the blue half remains.
	const sample = join(directory, "sample.bmp");
	await exec("/usr/bin/sips", ["-s", "format", "bmp", path, "--out", sample]);
	const bytes = await readFile(sample);
	const offset = bytes.readUInt32LE(10);
	assert.deepEqual([...bytes.subarray(offset, offset + 3)], [255, 0, 0]);
	await assert.rejects(
		saveCapture(capture, directory, join(directory, "out.png"), {
			save_path: join(directory, "out.png"),
			region: { x: 990, y: 30, width: 20, height: 10 },
		}, area, tools, signal),
		/inside the captured area/,
	);
	await assert.rejects(
		saveCapture(capture, directory, join(directory, "out.png"), { save_path: "x", region }, undefined, tools, signal),
		/no desktop bounds/,
	);
});

test("a file that appears after validation is not replaced without overwrite", { skip }, async (t) => {
	const { directory, capture } = await fixture();
	t.after(() => rm(directory, { recursive: true, force: true }));
	const path = join(directory, "late.png");
	await writeFile(path, "kept");
	await assert.rejects(saveCapture(capture, directory, path, { save_path: path }, undefined, tools, signal), /EEXIST/);
	assert.equal(await readFile(path, "utf8"), "kept");
	await saveCapture(capture, directory, path, { save_path: path, overwrite: true }, undefined, tools, signal);
	assert.ok(isPng(await readFile(path)));
});

test("a non-PNG capture is converted", { skip }, async (t) => {
	const { directory } = await fixture();
	t.after(() => rm(directory, { recursive: true, force: true }));
	const path = join(directory, "converted.png");
	const saved = await saveCapture(join(directory, "capture.bmp"), directory, path, { save_path: path }, undefined, tools, signal);
	assert.equal(saved.width, 200);
	assert.ok(isPng(await readFile(path)));
});

test("a clipboard image is saved byte for byte under a path that names its type", async (t) => {
	const folder = await mkdtemp(join(tmpdir(), "clipboard-save-"));
	t.after(() => rm(folder, { recursive: true, force: true }));
	const exported = join(folder, "original");
	const bytes = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
	await writeFile(exported, bytes);
	const source = { uti: "public.jpeg", mimeType: "image/jpeg", bytes: bytes.length, width: 4, height: 2 };

	await assert.rejects(validateSave({ save_path: join(folder, "a.gif") }, CLIPBOARD_SAVE_EXTENSIONS), /\.png, \.jpg, \.jpeg, \.tif or \.tiff/);
	assert.equal(await validateSave({ save_path: join(folder, "a.JPG") }, CLIPBOARD_SAVE_EXTENSIONS), join(folder, "a.JPG"));
	await assert.rejects(validateSave({ save_path: join(folder, "a.jpg") }), /ending in \.png\./);

	await assert.rejects(
		saveClipboardImage(exported, join(folder, "a.png"), false, source, signal),
		/image\/jpeg image; save it with a \.jpg or \.jpeg path/,
	);
	assert.equal(existsSync(join(folder, "a.png")), false);

	const saved = await saveClipboardImage(exported, join(folder, "a.jpeg"), false, source, signal);
	assert.deepEqual(saved, { path: join(folder, "a.jpeg"), uti: "public.jpeg", mime_type: "image/jpeg", bytes: 8, width: 4, height: 2 });
	assert.deepEqual(await readFile(join(folder, "a.jpeg")), bytes);

	await assert.rejects(saveClipboardImage(exported, join(folder, "a.jpeg"), false, source, signal), /EEXIST/);
	await saveClipboardImage(exported, join(folder, "a.jpeg"), true, source, signal);
	await assert.rejects(
		saveClipboardImage(exported, join(folder, "b.jpg"), false, { ...source, bytes: 9 }, signal),
		/incomplete/,
	);
});
