#!/usr/bin/env node
// Measures what each desktop tool result costs an agent: the text it reads and the screenshot it is sent.
// Runs a fixed observe-and-act loop against the dev app (npm run dev-app) on a TextEdit document, a Finder
// window and System Settings, then prints a table. Usage: node scripts/result-sizes.mjs [--json]
import { mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

import { createDesktop } from "../dist/client.js";
import { desktopRequest, desktopTools } from "../dist/tools.js";

const state = process.env.DESKTOP_TOOLS_STATE || join(homedir(), ".local", "state", "desktop-tools-dev");
const desktop = createDesktop({
	client: join(state, "desktop-client"),
	socket: join(state, "desktop.sock"),
	name: "Desktop Tools Dev",
});
const tools = new Map(desktopTools({ place: "this Mac", app: "Desktop Tools Dev" }).map((tool) => [tool.name, tool]));

const rows = [];
// --dump <dir> writes each result's text there, numbered in call order.
const dumpAt = process.argv.indexOf("--dump");
const dump = dumpAt > 0 ? process.argv[dumpAt + 1] : undefined;
if (dump) mkdirSync(dump, { recursive: true });

/** Calls one tool and records the size of what MCP would send: the outcome line, the text and the image. */
async function call(label, name, args) {
	const result = await desktop(desktopRequest(tools.get(name), args), AbortSignal.timeout(60_000));
	const text = (result.outcome ? `Outcome: ${result.outcome}.` : "") + result.text;
	const image = result.image ? imageSize(result.image.data) : undefined;
	if (dump) writeFileSync(join(dump, `${String(rows.length + 1).padStart(2, "0")} ${label}.json`), result.text);
	rows.push({
		case: label,
		tool: name,
		outcome: result.outcome ?? (result.isError ? "error" : "ok"),
		chars: text.length,
		image: image ? `${image.width}×${image.height}` : "",
		// Claude bills an image at about width × height / 750 tokens.
		image_tokens: image ? Math.round(image.width * image.height / 750) : 0,
	});
	return result.data;
}

/** The pixel size of a base64 JPEG, read from its SOF marker. */
function imageSize(base64) {
	const bytes = Buffer.from(base64, "base64");
	for (let i = 2; i < bytes.length - 9;) {
		if (bytes[i] !== 0xff) break;
		const marker = bytes[i + 1];
		if (marker >= 0xc0 && marker <= 0xc3) return { height: bytes.readUInt16BE(i + 5), width: bytes.readUInt16BE(i + 7) };
		i += 2 + bytes.readUInt16BE(i + 2);
	}
	return undefined;
}

async function app(bundle) {
	const data = await call(`apps (${bundle})`, "desktop_apps", { query: bundle });
	const row = data.apps.find((app) => app.bundle_id === bundle);
	if (!row) throw new Error(`${bundle} isn't running.`);
	return row;
}

/** The app's frontmost visible, titled window, with its target. */
async function window(label, pid) {
	const data = await call(`windows (${label})`, "desktop_windows", { pid });
	// Rows are whole with DESKTOP_TOOLS_VERBOSE=1 and compact otherwise; both carry the target.
	const found = data.windows.find((w) => w.availability?.state === "available" && w.target.bounds.height > 100);
	if (!found) throw new Error(`No visible ${label} window.`);
	return found.target ?? found;
}

const fixture = "/tmp/desktop-tools-result-sizes";
mkdirSync(fixture, { recursive: true });
writeFileSync(join(fixture, "note.txt"), "A short note for measuring result sizes.\n");

await call("apps (all)", "desktop_apps", {});

// TextEdit: the full loop.
await call("open note.txt", "desktop_open", { item: { path: join(fixture, "note.txt") }, application: { bundle_id: "com.apple.TextEdit" } });
await delay(1500);
const textEdit = await app("com.apple.TextEdit");
let target = await window("TextEdit", textEdit.pid);
let observed = await call("inspect (TextEdit)", "desktop_inspect", { pid: target.pid, window: target.window_id });
await call("minimize (TextEdit)", "desktop_minimize", { target });
target = await window("TextEdit", textEdit.pid).catch(() => target);
await call("restore (TextEdit)", "desktop_restore", { target: { ...target, is_minimized: true } });
await delay(500);
target = await window("TextEdit", textEdit.pid);
await call("focus (TextEdit)", "desktop_focus", { target });
observed = await call("inspect (TextEdit)", "desktop_inspect", { pid: target.pid, window: target.window_id });
const area = observed.ui_elements.find((element) => (element.identifier ?? element.attributes?.identifier) === "First Text View");
await call("click (TextEdit)", "desktop_click", { snapshot: observed.snapshot_id, element: area.id });

// Finder: a folder window.
await call("open folder", "desktop_open", { item: { path: fixture } });
await delay(1500);
const finder = await app("com.apple.finder");
target = await window("Finder", finder.pid);
await call("inspect (Finder)", "desktop_inspect", { pid: target.pid, window: target.window_id });

// System Settings: a large Accessibility tree.
await call("open System Settings", "desktop_open", { item: { path: "/System/Applications/System Settings.app" } });
await delay(2500);
const settings = await app("com.apple.systempreferences");
target = await window("System Settings", settings.pid);
await call("inspect (System Settings)", "desktop_inspect", { pid: target.pid, window: target.window_id });

if (process.argv.includes("--json")) {
	console.log(JSON.stringify(rows, null, "\t"));
} else {
	console.log("| case | outcome | text chars | image | image tokens |");
	console.log("|---|---|---:|---|---:|");
	for (const row of rows) {
		console.log(`| ${row.case} | ${row.outcome} | ${row.chars.toLocaleString("en")} | ${row.image} | ${row.image_tokens.toLocaleString("en")} |`);
	}
	const chars = rows.reduce((sum, row) => sum + row.chars, 0);
	const images = rows.reduce((sum, row) => sum + row.image_tokens, 0);
	console.log(`| **total** | | **${chars.toLocaleString("en")}** | | **${images.toLocaleString("en")}** |`);
}
