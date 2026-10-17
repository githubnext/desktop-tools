import assert from "node:assert/strict";
import { test } from "node:test";
import { createDesktop } from "../dist/client.js";
import { desktopTools } from "../dist/tools.js";

// Every request here is refused before the native client would run.
const desktop = createDesktop({ client: "/nonexistent/desktop-client", socket: "/nonexistent/desktop.sock", name: "test" });
const signal = new AbortController().signal;
const macOS = { skip: process.platform !== "darwin" && "the client validates only on macOS" };

async function refusal(request) {
	const result = await desktop({ op: "insert", snapshot: "S1", ...request }, signal);
	assert.equal(result.outcome, "refused", JSON.stringify(request));
	return JSON.parse(result.text).action.reason;
}

test("an attachment insertion takes an image path or 1–32 file paths, and no text or route", macOS, async () => {
	assert.match(await refusal({ format: "image", path: "/tmp/a.png", text: "x" }), /without text or route/);
	assert.match(await refusal({ format: "files", paths: ["/tmp/a"], route: "paste" }), /without text or route/);
	assert.match(await refusal({ format: "image", paths: ["/tmp/a.png"] }), /without text or route/);
	assert.match(await refusal({ format: "image", path: "relative.png" }), /one absolute image path/);
	assert.match(await refusal({ format: "pdf", path: "/tmp/a.pdf" }), /format image|format files/);
	assert.match(await refusal({ format: "files", paths: [] }), /1–32 absolute/);
	assert.match(await refusal({ format: "files", paths: Array(33).fill("/tmp/a") }), /1–32 absolute/);
	assert.match(await refusal({ format: "files", paths: ["/tmp/a\0b"] }), /1–32 absolute/);
	assert.match(await refusal({ format: "files", paths: ["/tmp/a"], clipboard: "keep" }), /restore or replace/);
});

test("a text insertion still needs text", macOS, async () => {
	assert.match(await refusal({}), /1 to 8192/);
});

test("a missing image or file is refused before the native client runs", macOS, async () => {
	await refusal({ format: "image", path: "/nonexistent/desktop-tools-attachment.png", clipboard: "replace" });
	await refusal({ format: "files", paths: ["/nonexistent/desktop-tools-attachment.pdf"] });
});

test("desktop_insert exposes the attachment form and the clipboard choice", () => {
	const insert = desktopTools({ place: "this Mac", app: "Desktop Tools" }).find((tool) => tool.name === "desktop_insert");
	assert.deepEqual(insert.parameters.required, ["snapshot"]);
	const { format, paths, clipboard } = insert.parameters.properties;
	assert.deepEqual(format.enum, ["image", "files"]);
	assert.equal(paths.maxItems, 32);
	assert.deepEqual(clipboard.enum, ["restore", "replace"]);
	assert.match(insert.description, /PASTE_UNVERIFIABLE_RECEIVER/);
	assert.match(insert.description, /left_replaced/);
	assert.match(insert.description, /Finder window.*PASTE_NAME_EXISTS/);
});
