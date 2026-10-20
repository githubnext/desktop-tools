#!/usr/bin/env node
// Runs the automatable live checks from #42 against Desktop Tools through the real MCP server.
// It works only on fixtures it creates and windows it opens, and closes them at the end, even on failure.
import { spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { parseArgs } from "node:util";
import { deflateSync } from "node:zlib";

const { values } = parseArgs({
	options: {
		only: { type: "string", multiple: true },
		list: { type: "boolean" },
		json: { type: "string" },
		"keep-fixtures": { type: "boolean" },
		server: { type: "string" },
		help: { type: "boolean", short: "h" },
	},
	strict: true,
});
if (values.help) {
	console.log(`Usage: npm run live-check -- [--only <pr>[,<pr>]] [--list] [--json <path>] [--keep-fixtures] [--server <path>]

Drives the installed Desktop Tools, or the dev app whose state folder is DESKTOP_TOOLS_STATE
(~/.local/state/desktop-tools-dev for npm run dev-app), through dist/mcp.js, or through the MCP server executable
--server names. Refuses to run while the screen is locked. See docs/live-checks.md.`);
	process.exit(0);
}
const only = new Set((values.only ?? []).flatMap((v) => v.split(",")).map((v) => v.trim().replace(/^#/, "")).filter(Boolean));

const TEXTEDIT = "com.apple.TextEdit";
const FINDER = "com.apple.finder";
const CHROME = "com.google.Chrome";
const SAFARI = "com.apple.Safari";
const run = randomBytes(3).toString("hex");
const HOST = "dev.githubnext.desktop-tools";
const STATE = process.env.DESKTOP_TOOLS_STATE || join(homedir(), ".local", "state", "desktop-tools");

// ---------- MCP client ----------

class Mcp {
	/** `launcher` runs the server under another program, which the host then sees as its caller. */
	constructor(launcher = []) {
		this.next = 1;
		this.waiting = new Map();
		const server = values.server ? [values.server] : [process.execPath, new URL("../dist/mcp.js", import.meta.url).pathname];
		const command = [...launcher, ...server];
		this.child = spawn(command[0], command.slice(1), {
			stdio: ["pipe", "pipe", "inherit"],
			env: process.env,
		});
		let buffer = "";
		this.child.stdout.on("data", (chunk) => {
			buffer += chunk;
			let newline;
			while ((newline = buffer.indexOf("\n")) >= 0) {
				const line = buffer.slice(0, newline);
				buffer = buffer.slice(newline + 1);
				if (!line.trim()) continue;
				const message = JSON.parse(line);
				const pending = this.waiting.get(message.id);
				if (!pending) continue;
				this.waiting.delete(message.id);
				if (message.error) pending.reject(new Error(message.error.message));
				else pending.resolve(message.result);
			}
		});
		this.child.on("exit", (code) => {
			for (const { reject } of this.waiting.values()) reject(new Error(`MCP server exited (${code}).`));
			this.waiting.clear();
		});
	}

	request(method, params) {
		const id = this.next++;
		return new Promise((resolve, reject) => {
			this.waiting.set(id, { resolve, reject });
			this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
		});
	}

	async start() {
		await this.request("initialize", {
			protocolVersion: "2025-06-18",
			capabilities: {},
			clientInfo: { name: "live-check", title: "Live check" },
		});
		this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" })}\n`);
		const { tools } = await this.request("tools/list", {});
		this.tools = new Map(tools.map((tool) => [tool.name, tool]));
	}

	/** Calls one tool; returns its outcome, its JSON payload, and the raw text. */
	async call(name, args = {}) {
		const result = await this.request("tools/call", { name, arguments: args });
		let outcome;
		let data;
		const texts = [];
		for (const item of result.content ?? []) {
			if (item.type !== "text") continue;
			const match = /^Outcome: (\w+)\.$/.exec(item.text);
			if (match) {
				outcome = match[1];
				continue;
			}
			texts.push(item.text);
			try {
				data ??= JSON.parse(item.text);
			} catch {}
		}
		return { outcome, data: data ?? {}, text: texts.join("\n"), isError: result.isError === true };
	}

	stop() {
		this.child.stdin.end();
		this.child.stdout.destroy();
		this.child.unref();
		setTimeout(() => this.child.kill(), 2000).unref();
	}
}

// ---------- small helpers ----------

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const action = (result) => result.data.action ?? result.data;
const brief = (value, max = 240) => {
	// JSON.stringify(undefined) is undefined, not a string.
	const text = typeof value === "string" ? value : String(JSON.stringify(value));
	return text.length > max ? `${text.slice(0, max)}…` : text;
};

/** The first value under `key` anywhere in a result. */
function dig(value, key) {
	if (!value || typeof value !== "object") return undefined;
	if (key in value) return value[key];
	for (const child of Object.values(value)) {
		const found = dig(child, key);
		if (found !== undefined) return found;
	}
	return undefined;
}

function evidence(result, ...keys) {
	const act = action(result);
	const parts = [`outcome ${result.outcome ?? (result.isError ? "error" : "ok")}`];
	for (const key of keys) {
		const value = dig(act, key);
		if (value !== undefined) parts.push(`${key} ${brief(value, 120)}`);
	}
	const code = dig(act, "code");
	if (code && !keys.includes("code")) parts.push(`code ${code}`);
	if (result.outcome !== "completed" && !result.outcome && result.isError) parts.push(brief(result.text, 160));
	else if (result.outcome && result.outcome !== "completed") {
		const message = dig(act, "message");
		if (message && !keys.includes("message")) parts.push(`message ${brief(message, 200)}`);
	}
	return parts.join(", ");
}

class Skip extends Error {}
const skip = (reason) => {
	throw new Skip(reason);
};
const expect = (condition, detail) => ({ status: condition ? "pass" : "fail", detail });

/** A minimal RGB PNG, so fixtures need no image tools. */
function png(width, height, seed) {
	const crc = (buffer) => {
		let c;
		let value = ~0;
		for (const byte of buffer) {
			c = (value ^ byte) & 0xff;
			for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
			value = (value >>> 8) ^ c;
		}
		return ~value >>> 0;
	};
	const chunk = (type, body) => {
		const length = Buffer.alloc(4);
		length.writeUInt32BE(body.length);
		const tagged = Buffer.concat([Buffer.from(type), body]);
		const sum = Buffer.alloc(4);
		sum.writeUInt32BE(crc(tagged));
		return Buffer.concat([length, tagged, sum]);
	};
	const header = Buffer.alloc(13);
	header.writeUInt32BE(width, 0);
	header.writeUInt32BE(height, 4);
	header[8] = 8;
	header[9] = 2;
	const rows = [];
	for (let y = 0; y < height; y++) {
		const row = Buffer.alloc(1 + width * 3);
		for (let x = 0; x < width; x++) {
			row[1 + x * 3] = (x * 4 + seed) & 0xff;
			row[2 + x * 3] = (y * 4) & 0xff;
			row[3 + x * 3] = ((x + y) * 2) & 0xff;
		}
		rows.push(row);
	}
	return Buffer.concat([
		Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
		chunk("IHDR", header),
		chunk("IDAT", deflateSync(Buffer.concat(rows))),
		chunk("IEND", Buffer.alloc(0)),
	]);
}

function pngSize(path) {
	const bytes = readFileSync(path);
	if (bytes.readUInt32BE(0) !== 0x89504e47) return null;
	return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
}

const sha = (path) => createHash("sha256").update(readFileSync(path)).digest("hex");

// ---------- fixtures ----------

const PAGE = (title) => `<!doctype html>
<html><head><meta charset="utf-8"><title>${title}</title>
<style>body{font:16px -apple-system;margin:24px}input,div[contenteditable]{font:16px -apple-system;margin:4px 0}
table{border-collapse:collapse}td,th{border:1px solid #888;padding:4px 8px}</style></head>
<body>
<h1>${title}</h1>
<p id="prose">The quick brown fox jumps over the lazy dog near <a href="#anchor">the riverbank link</a> today.</p>
<form onsubmit="return false">
<label>Controlled <input id="controlled" aria-label="Controlled field"></label>
<label>Other <input id="other" aria-label="Other field"></label>
<label>Date <input id="date" type="date" aria-label="Date field"></label>
</form>
<p>State: <output id="state" aria-label="State mirror">state:</output></p>
<p>Date state: <output id="datestate" aria-label="Date mirror">date:</output></p>
<div id="editable" contenteditable="true" aria-label="Editable area" style="border:1px solid #888;min-height:2em"></div>
<table id="fruit" aria-label="Fruit table">
<thead><tr><th>Fruit</th><th>Count</th></tr></thead>
<tbody><tr><td>Apple</td><td>3</td></tr><tr><td>Pear</td><td>5</td></tr><tr><td>Plum</td><td>8</td></tr></tbody>
</table>
<table id="grid" aria-label="Edit grid" role="grid">
<thead><tr><th>Name</th><th>Note</th></tr></thead>
<tbody><tr><td>Row one</td><td><input aria-label="Note one" value="alpha"></td></tr>
<tr><td>Row two</td><td><input aria-label="Note two" value="beta"></td></tr></tbody>
</table>
<script>
// A React-style controlled input: the value shown always comes from state, set on each input event.
const state = { value: "" };
const field = document.getElementById("controlled");
const mirror = document.getElementById("state");
field.addEventListener("input", (event) => {
	state.value = event.target.value;
	field.value = state.value;
	mirror.textContent = "state:" + state.value;
});
document.getElementById("date").addEventListener("input", (event) => {
	document.getElementById("datestate").textContent = "date:" + event.target.value;
});
</script>
</body></html>
`;

function makeFixtures() {
	const root = mkdtempSync(join(tmpdir(), `desktop-tools-live-${run}-`));
	const folder = join(root, `live-folder-${run}`);
	mkdirSync(folder);
	for (let i = 1; i <= 8; i++) writeFileSync(join(folder, `item-${String(i).padStart(2, "0")}.txt`), `item ${i}\n`);
	mkdirSync(join(folder, "sub-folder"));
	writeFileSync(join(folder, "sub-folder", "inner.txt"), "inner\n");
	const plain = join(root, `live-plain-${run}.txt`);
	writeFileSync(plain, "Live check plain document.\nSecond line.\n");
	const rich = join(root, `live-rich-${run}.rtf`);
	writeFileSync(rich, "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\\f0\\fs28 Live check rich document. Replace WORD here.\\par}");
	// TextEdit takes an image paste into an RTFD document; into an .rtf one it asks to convert first.
	const rtfd = join(root, `live-rtfd-${run}.rtfd`);
	mkdirSync(rtfd);
	writeFileSync(join(rtfd, "TXT.rtf"), "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\\f0\\fs28 Live check RTFD document.\\par}");
	const page = join(root, `live-page-${run}.html`);
	writeFileSync(page, PAGE(`Live page ${run}`));
	const sources = join(root, "paste-sources");
	mkdirSync(sources);
	for (const name of ["pasted-a.txt", "pasted-b.txt", "item-02.txt"]) writeFileSync(join(sources, name), `${name}\n`);
	const image = join(root, "fixture.png");
	writeFileSync(image, png(64, 48, 17));
	// Saving refuses a folder that doesn't exist yet.
	const captures = join(root, "captures");
	mkdirSync(captures);
	return { root, folder, plain, rich, rtfd, page, image, sources, captures };
}

// ---------- session: what the harness opened, and how to put it back ----------

class Session {
	constructor(mcp, fixtures) {
		this.mcp = mcp;
		this.fixtures = fixtures;
		this.opened = []; // { pid, window_id, label }
		this.launched = new Map(); // bundle_id -> target, apps not running before
		this.memo = new Map();
		this.restore = []; // async functions, run last first
		this.chromes = new Set(); // isolated Chrome instances: { child, profile, target }
	}

	async runningTarget(bundleId) {
		const { data } = await this.mcp.call("desktop_apps", { query: bundleId });
		const app = (data.apps ?? []).find((a) => a.bundle_id === bundleId);
		return app?.target ?? null;
	}

	async windows(pid) {
		const { data } = await this.mcp.call("desktop_windows", { pid });
		// Compact rows (#144) carry the title as title and the window number only in target.
		return (data.windows ?? []).map((w) => ({
			...w, window_id: w.window_id ?? w.target?.window_id, window_title: w.window_title ?? w.title ?? "", bounds: w.bounds ?? w.target?.bounds,
		}));
	}

	/** Opens a fixture in an app and returns its new window, tracked for cleanup. */
	async openWindow(path, bundleId, titlePart, label) {
		const before = await this.runningTarget(bundleId);
		const beforeIds = new Set(before ? (await this.windows(before.pid)).map((w) => w.window_id) : []);
		const opened = await this.mcp.call("desktop_open", { item: { path }, application: { bundle_id: bundleId } });
		if (opened.outcome === "refused") throw new Error(`desktop_open refused: ${brief(opened.text)}`);
		const target = dig(opened.data, "application")?.target ?? (await this.runningTarget(bundleId));
		if (!target) throw new Error(`${bundleId} did not start.`);
		if (!before) this.launched.set(bundleId, target);
		for (let attempt = 0; attempt < 20; attempt++) {
			const found = (await this.windows(target.pid)).find(
				(w) => !beforeIds.has(w.window_id) && w.window_title.includes(titlePart),
			);
			if (found) {
				this.opened.push({ pid: target.pid, window_id: found.window_id, label });
				return { pid: target.pid, window: found.window_id, target, info: found };
			}
			await sleep(500);
		}
		const tab = before ? " It may have opened as a tab in one of the user's windows, which the harness leaves alone." : "";
		throw new Error(`No new window titled like "${titlePart}" appeared in ${bundleId}.${tab}`);
	}

	/** Records windows an action created in an app, so cleanup closes them too. */
	async adopt(pid, beforeIds, label) {
		for (const w of await this.windows(pid)) {
			if (!beforeIds.has(w.window_id) && !this.opened.some((o) => o.window_id === w.window_id)) {
				this.opened.push({ pid, window_id: w.window_id, label });
			}
		}
	}

	once(key, make) {
		if (!this.memo.has(key)) this.memo.set(key, make().catch((error) => ({ error })));
		return this.memo.get(key).then((value) => {
			if (value?.error) throw value.error;
			return value;
		});
	}

	textedit(kind) {
		const path = this.fixtures[kind];
		return this.once(`textedit-${kind}`, () =>
			this.openWindow(path, TEXTEDIT, `live-${kind}-${run}`, `TextEdit ${kind} document`),
		);
	}

	finder() {
		return this.once("finder", async () => {
			const win = await this.openWindow(this.fixtures.folder, FINDER, `live-folder-${run}`, "Finder fixture folder");
			// List view, for this window's folder only.
			const { snap } = await this.inspect(win);
			await this.mcp.call("desktop_key", { snapshot: snap, key: "2", modifiers: ["command"] });
			await sleep(800);
			return win;
		});
	}

	web() {
		return this.once("web", async () => {
			const running = await this.runningTarget(SAFARI);
			if (running && (await this.windows(running.pid)).length > 0) {
				skip("Safari is open with the user's windows, and a fixture page could open as a tab in one; quit Safari to run web checks");
			}
			const win = await this.openWindow(this.fixtures.page, SAFARI, `Live page ${run}`, "Safari fixture page");
			// A freshly launched Safari lists the window seconds before its web area holds the page.
			const loaded = await this.mcp.call("desktop_wait", {
				until: "text_contains", pid: win.pid, window: win.window, text: "quick brown fox", timeout_ms: 20000,
			});
			if (loaded.data?.status !== "matched") throw new Error(`The Safari fixture page didn't load: ${brief(loaded.text, 200)}`);
			return win;
		});
	}

	async inspect(win, extra = {}) {
		const result = await this.mcp.call("desktop_inspect", { pid: win.pid, window: win.window, ...extra });
		const snap = result.data.snapshot_id;
		if (!snap) throw new Error(`desktop_inspect returned no snapshot: ${brief(result.text)}`);
		return { snap, els: result.data.ui_elements ?? [], result };
	}

	async read(win, extra = {}) {
		return this.mcp.call("desktop_read", { pid: win.pid, window: win.window, ...extra });
	}

	/**
	 * A fresh, isolated Chrome on the fixture page: its own temporary profile, so it never shares a process, window
	 * or setting with the user's Chrome. Each call launches a new instance, whose web accessibility starts off.
	 */
	async launchChrome() {
		const app = ["/Applications/Google Chrome.app", join(homedir(), "Applications", "Google Chrome.app")].find((path) =>
			existsSync(join(path, "Contents", "MacOS", "Google Chrome")),
		) ?? skip("Google Chrome isn't installed in /Applications or ~/Applications; the Chromium checks need it");
		const profile = mkdtempSync(join(tmpdir(), `desktop-tools-live-chrome-${run}-`));
		const child = spawn(
			join(app, "Contents", "MacOS", "Google Chrome"),
			[`--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check", "--new-window", pathToFileURL(this.fixtures.page).href],
			{ stdio: "ignore", detached: true },
		);
		const chrome = { child, profile, target: null, exited: new Promise((resolve) => child.once("exit", resolve)) };
		child.once("error", () => {}); // A failed spawn shows as no window below.
		child.unref();
		this.chromes.add(chrome);
		for (let attempt = 0; attempt < 40 && child.exitCode === null; attempt++) {
			const { data } = await this.mcp.call("desktop_apps", { query: CHROME });
			chrome.target ??= (data.apps ?? []).find((a) => a.pid === child.pid)?.target ?? null;
			if (chrome.target) {
				const win = (await this.windows(child.pid)).find((w) => (w.window_title ?? "").includes(`Live page ${run}`));
				if (win) return { pid: child.pid, window: win.window_id, target: chrome.target, info: win, chrome };
			}
			await sleep(500);
		}
		await this.quitChrome(chrome);
		throw new Error(`The isolated Chrome (pid ${child.pid}) showed no window for the fixture page.`);
	}

	/** Quits only the Chrome process the harness started, then removes its profile. */
	async quitChrome(chrome, log = () => {}) {
		if (!this.chromes.delete(chrome)) return;
		const { child, profile, target } = chrome;
		if (child.exitCode === null && target) {
			const quit = await this.mcp.call("desktop_quit", { target });
			log(`quit the isolated Chrome (pid ${child.pid}): ${quit.outcome}`);
		}
		const gone = await Promise.race([chrome.exited.then(() => true), sleep(8000).then(() => false)]);
		if (!gone && child.exitCode === null) {
			// The child is this harness's own process, never the user's Chrome.
			child.kill("SIGTERM");
			log(`terminated the isolated Chrome (pid ${child.pid}), which didn't quit in time`);
			await Promise.race([chrome.exited, sleep(3000)]);
		}
		rmSync(profile, { recursive: true, force: true });
	}

	async cleanup(log) {
		for (const chrome of [...this.chromes]) {
			try {
				await this.quitChrome(chrome, log);
			} catch (error) {
				log(`could not quit the isolated Chrome (pid ${chrome.child.pid}): ${error.message}`);
			}
		}
		for (const undo of this.restore.reverse()) {
			try {
				await undo();
			} catch (error) {
				log(`restore failed: ${error.message}`);
			}
		}
		for (const { pid, window_id, label } of this.opened.reverse()) {
			try {
				const win = (await this.windows(pid)).find((w) => w.window_id === window_id);
				if (!win) continue;
				const closed = await this.mcp.call("desktop_close", { target: win.target });
				await sleep(500);
				const left = (await this.windows(pid)).find((w) => w.window_id === window_id);
				if (left) await this.dismissSave(left.target);
				log(`closed ${label} (window ${window_id}): ${closed.outcome}`);
			} catch (error) {
				log(`could not close ${label} (window ${window_id}): ${error.message}`);
			}
		}
		for (const [bundleId, target] of this.launched) {
			try {
				const quit = await this.mcp.call("desktop_quit", { target });
				log(`quit ${bundleId}, which the harness launched: ${quit.outcome}`);
			} catch (error) {
				log(`could not quit ${bundleId}: ${error.message}`);
			}
		}
	}

	/** A closed fixture document may ask to save; answer only on the harness's own window. */
	async dismissSave(target) {
		const dialog = await this.mcp.call("desktop_dialog", { target });
		const titles = (dig(dialog.data, "buttons") ?? []).map((b) => b.title);
		const button = ["Delete", "Don’t Save", "Don't Save", "Revert Changes"].find((b) => titles.includes(b));
		if (button) await this.mcp.call("desktop_dialog_answer", { target, button });
	}
}

// ---------- element helpers ----------

const label = (e) => `${e.label ?? ""} ${e.attributes?.title ?? ""} ${e.attributes?.description ?? ""}`;
/** inspect's type for an Accessibility role it names; other roles stay as they are. */
const TYPES = { AXTextField: "textField", AXTextArea: "textField", AXSearchField: "textField", AXLink: "link", AXButton: "button" };
/** Whether an element has the Accessibility `role`: compact rows (#144) give only inspect's type, such as textField. */
const hasRole = (e, role) => (e.attributes?.role ?? e.role) === role || (TYPES[role] !== undefined && e.role === TYPES[role]);
const find = (els, role, pattern) =>
	els.find((e) => hasRole(e, role) && (!pattern || pattern.test(label(e)) || pattern.test(e.value ?? "")));
const findOrSkip = (els, role, pattern, what) => find(els, role, pattern) ?? skip(`no ${what} (${role}) found in the inspection`);
// A table read gives columns and rows at the top level; its table field only names the table.
const tableOf = (result) => Array.isArray(result.data.rows) ? result.data : null;

async function finderTable(s) {
	const win = await s.finder();
	const { snap, els } = await s.inspect(win);
	// The sidebar is an outline too, listed first.
	const lists = els.filter((e) => (hasRole(e, "AXOutline") || hasRole(e, "AXTable")) && !/sidebar/i.test(label(e)));
	const outline = lists[0] ?? skip("Finder window has no list outline; list view did not apply");
	const read = await s.read(win, { scope: { snapshot: snap, element: outline.id }, table: true });
	return { win, snap, outline, read, table: tableOf(read) };
}

const selectedNames = (table) => (table?.rows ?? []).filter((r) => r.selected).map((r) => r.cells?.[0]);

// ---------- checks, grouped by PR; newest releases first ----------

const checks = [];
const check = (pr, title, run, notes) => checks.push({ pr: String(pr), title, run, notes });

/** Runs a check against its own fresh isolated Chrome, so web accessibility starts off, and quits it after. */
const withChrome = (body) => async (s, m) => {
	const win = await s.launchChrome();
	try {
		return await body(s, m, win);
	} finally {
		await s.quitChrome(win.chrome);
	}
};
const ISOLATED = "Launches an isolated Chrome (temporary profile, no first-run UI) on the fixture page, then quits only that process and deletes the profile.";

// Unreleased

/** Whether the host asks before serving callers: it keeps their answers, and the harness's own caller needs one. */
const approvesCallers = () =>
	existsSync(join(STATE, "callers.json")) || skip("this host doesn't approve callers (#120 not in it)");

check(120, "input to Desktop Tools itself is refused with SELF_TARGET_REFUSED, and observing it still works", async (s, m) => {
	approvesCallers();
	const { data } = await m.call("desktop_apps", { query: HOST });
	// The installed app or the dev app, whose ID is under it.
	const host = (data.apps ?? []).find((a) => a.bundle_id === HOST || a.bundle_id?.startsWith(`${HOST}.`))
		?? skip("no Desktop Tools app is listed");
	const windows = await m.call("desktop_windows", { pid: host.target.pid });
	const result = await m.call("desktop_activate", { target: host.target });
	return expect(
		!windows.isError && result.outcome === "refused" && /SELF_TARGET_REFUSED/.test(result.text),
		`windows listed ${!windows.isError}; activate ${evidence(result)}`,
	);
}, "Lists the windows of a running Desktop Tools and asks to activate it, which is refused before dispatch; any build in the family counts.");

// 0.13.0
const finderPaste = (m) =>
	/PASTE_NAME_EXISTS/.test(m.tools.get("desktop_insert")?.description ?? "") ||
	skip("this build's desktop_insert doesn't paste into Finder folders (#114 not in it)");

/** A Finder fixture window whose file list has focus, freshly inspected. */
async function finderListFocus(s, m) {
	const first = await finderTable(s);
	const row = first.table?.rows?.find((r) => r.element) ?? skip("no Finder row has an ID");
	await m.call("desktop_click", { snapshot: first.snap, element: row.element });
	// A background Finder window has no blank title bar to make it key, so a files paste needs Finder forward; Node's
	// desktop_open brings it forward, and native2's opens it in the background (#162).
	await m.call("desktop_focus", { target: first.win.info.target });
	return s.inspect(first.win);
}

check(114, "desktop_insert format files copies into a Finder folder and restores the clipboard", async (s, m) => {
	finderPaste(m);
	await s.clipboard();
	const { snap } = await finderListFocus(s, m);
	const known = `live-check-known-${run}`;
	await m.call("desktop_clipboard_write", { text: known });
	const paths = ["pasted-a.txt", "pasted-b.txt"].map((n) => join(s.fixtures.sources, n));
	const result = await m.call("desktop_insert", { snapshot: snap, format: "files", paths });
	await sleep(500);
	const copied = ["pasted-a.txt", "pasted-b.txt"].every((n) => existsSync(join(s.fixtures.folder, n)));
	const after = await m.call("desktop_clipboard_read", { format: "text" });
	const act = action(result);
	return expect(
		result.outcome === "completed" && act.copy === "started" && copied && after.data.text === known,
		`${evidence(result, "folder", "copy", "consumption", "clipboard_cleanup")}; files ${copied ? "present" : "missing"}; clipboard after ${brief(after.data.text, 40)}`,
	);
});

check(114, "desktop_insert format files refuses a name already in the Finder folder, before input", async (s, m) => {
	finderPaste(m);
	await s.clipboard();
	const { snap } = await finderListFocus(s, m);
	const before = await m.call("desktop_clipboard_read", { format: "text" });
	const result = await m.call("desktop_insert", {
		snapshot: snap, format: "files", paths: [join(s.fixtures.sources, "item-02.txt")],
	});
	const after = await m.call("desktop_clipboard_read", { format: "text" });
	const kept = readFileSync(join(s.fixtures.folder, "item-02.txt"), "utf8") === "item 2\n";
	return expect(
		result.outcome === "refused" && /PASTE_NAME_EXISTS/.test(result.text) && kept && before.data.change_count === after.data.change_count,
		`${evidence(result)}; existing file ${kept ? "unchanged" : "changed"}; change_count ${before.data.change_count} → ${after.data.change_count}`,
	);
});

// 0.12.0
check(111, "desktop_read right after Chrome launches returns the page, or fails saying it retried", withChrome(async (s, m, win) => {
	// No wait for the page to settle: the first read races Chrome building its web tree.
	const read = await s.read(win);
	const text = read.data.text ?? "";
	if (!read.isError) return expect(text.includes("quick brown fox"), `read ${read.data.web_accessibility}; page text ${text.includes("quick brown fox") ? "present" : "missing"}`);
	return expect(read.data.retried === true, `failed with retried ${read.data.retried}: ${brief(read.text, 160)}`);
}), `${ISOLATED} A read that succeeded may have retried once without saying so; only a failure after the retry reports it.`);

check(110, "desktop_wait element_appears on a fresh Chrome turns on web accessibility and finds a page element", withChrome(async (s, m, win) => {
	if (!m.tools.get("desktop_wait")?.inputSchema?.properties?.web_accessibility) skip("this build's desktop_wait has no web_accessibility (#110 not in it)");
	// Only the page has tables; Chrome's own toolbar has none, so a match needs the web tree.
	const result = await m.call("desktop_wait", { until: "element_appears", pid: win.pid, window: win.window, element: { role: "AXTable", title: "Fruit table" }, timeout_ms: 8000 });
	const state = result.data.match?.web_accessibility;
	const text = { until: "text_contains", pid: win.pid, window: win.window, text: "riverbank link", timeout_ms: 5000 };
	const kept = await m.call("desktop_wait", { ...text, web_accessibility: false });
	return expect(
		result.data.status === "matched" && state === "enabled"
			&& kept.data.status === "matched" && kept.data.match?.web_accessibility === undefined,
		`element ${result.data.status ?? brief(result.text, 200)}, web_accessibility ${state}; text with it opted out ${kept.data.status ?? brief(kept.text, 200)}, ${kept.data.match?.web_accessibility}`,
	);
}), ISOLATED);

// 0.11.0
check(107, "desktop_inspect turns on a fresh Chrome's web accessibility once, and lists the page's fields", withChrome(async (s, m, win) => {
	if (!m.tools.get("desktop_inspect")?.inputSchema?.properties?.web_accessibility) skip("this build's desktop_inspect has no web_accessibility (#107 not in it)");
	const first = await s.inspect(win);
	const field = find(first.els, "AXTextField", /Controlled field/);
	const again = await s.inspect(win);
	const kept = await s.inspect(win, { web_accessibility: false });
	return expect(
		first.result.data.web_accessibility === "enabled" && field
			&& again.result.data.web_accessibility === "already_on" && kept.result.data.web_accessibility === undefined,
		`first ${first.result.data.web_accessibility} with ${first.els.length} elements, field ${field ? "found" : "missing"}; again ${again.result.data.web_accessibility}; opted out ${kept.result.data.web_accessibility}`,
	);
}), ISOLATED);

check(107, "desktop_read leaves Safari's web accessibility alone and reports nothing", async (s, m) => {
	if (!m.tools.get("desktop_read")?.inputSchema?.properties?.web_accessibility) skip("this build's desktop_read has no web_accessibility (#107 not in it)");
	const win = await s.web();
	const read = await s.read(win);
	return expect(
		read.data.web_accessibility === undefined && (read.data.text ?? "").includes(`Live page ${run}`),
		`web_accessibility ${read.data.web_accessibility}; text ${brief(read.data.text, 80)}`,
	);
});

check(99, "desktop_insert pastes a PNG into a TextEdit RTFD document and restores the clipboard", async (s, m) => {
	const insert = m.tools.get("desktop_insert");
	if (!insert?.inputSchema?.properties?.format) skip("this build's desktop_insert has no attachment format (#99 not in it)");
	await s.clipboard();
	const win = await s.textedit("rtfd");
	const { snap, els } = await s.inspect(win);
	const area = findOrSkip(els, "AXTextArea", null, "text area");
	await m.call("desktop_click", { snapshot: snap, element: area.id });
	const fresh = await s.inspect(win);
	const known = `live-check-known-${run}`;
	const write = await m.call("desktop_clipboard_write", { text: known });
	if (write.outcome !== "completed") return expect(false, `clipboard write: ${evidence(write)}`);
	const result = await m.call("desktop_insert", { snapshot: fresh.snap, format: "image", path: s.fixtures.image });
	const after = await m.call("desktop_clipboard_read", { format: "text" });
	const act = action(result);
	return expect(
		result.outcome === "completed" && act.clipboard_cleanup === "restored" && after.data.text === known,
		`${evidence(result, "attachment_evidence", "clipboard_cleanup", "clipboard_ownership")}; clipboard after ${brief(after.data.text, 40)}`,
	);
});

check(99, "desktop_insert of an image into a web field refuses with PASTE_UNVERIFIABLE_RECEIVER", async (s, m) => {
	if (!m.tools.get("desktop_insert")?.inputSchema?.properties?.format) skip("this build's desktop_insert has no attachment format (#99 not in it)");
	await s.clipboard();
	const win = await s.web();
	const { snap, els } = await s.inspect(win);
	const field = findOrSkip(els, "AXTextField", /Other field/, "Other field");
	await m.call("desktop_click", { snapshot: snap, element: field.id });
	const fresh = await s.inspect(win);
	const before = await m.call("desktop_clipboard_read", { format: "text" });
	const result = await m.call("desktop_insert", { snapshot: fresh.snap, format: "image", path: s.fixtures.image });
	const after = await m.call("desktop_clipboard_read", { format: "text" });
	return expect(
		result.outcome === "refused" && /PASTE_UNVERIFIABLE_RECEIVER/.test(result.text) && before.data.change_count === after.data.change_count,
		`${evidence(result)}; change_count ${before.data.change_count} → ${after.data.change_count}`,
	);
});

// 0.10.0
check(96, "clipboard image save_path writes the PNG's original bytes", async (s, m) => {
	await s.clipboard();
	const write = await m.call("desktop_clipboard_write", { format: "image", path: s.fixtures.image });
	if (write.outcome !== "completed") return expect(false, `clipboard write: ${evidence(write)}`);
	const out = join(s.fixtures.captures, "clip.png");
	const read = await m.call("desktop_clipboard_read", { format: "image", save_path: out });
	const same = existsSync(out) && sha(out) === sha(s.fixtures.image);
	return expect(same, `saved ${brief(read.data.saved)}; bytes ${same ? "equal" : "differ or missing"}`);
});

check(96, "clipboard image save_path with a mismatched extension is refused and writes nothing", async (s, m) => {
	await s.clipboard();
	await m.call("desktop_clipboard_write", { format: "image", path: s.fixtures.image });
	const out = join(s.fixtures.captures, "clip-mismatch.jpg");
	const read = await m.call("desktop_clipboard_read", { format: "image", save_path: out });
	return expect(read.isError && !existsSync(out), `${brief(read.text, 200)}; file ${existsSync(out) ? "written" : "absent"}`);
});

check(96, "clipboard image save_path with no image saves null and writes nothing", async (s, m) => {
	await s.clipboard();
	const write = await m.call("desktop_clipboard_write", { text: `no image ${run}` });
	if (write.outcome !== "completed") return expect(false, `clipboard write: ${evidence(write)}`);
	const out = join(s.fixtures.captures, "clip-none.png");
	const read = await m.call("desktop_clipboard_read", { format: "image", save_path: out });
	return expect(read.data.saved === null && !existsSync(out), `saved ${brief(read.data.saved)}; file ${existsSync(out) ? "written" : "absent"}`);
});

check(90, "desktop_input_source selecting the current source reports changed false", async (s, m) => {
	const list = await m.call("desktop_input_source", {});
	const current = list.data.current ?? skip("no current input source reported");
	const result = await m.call("desktop_input_source", { select: current });
	return expect(result.outcome === "completed" && dig(result.data, "changed") === false, evidence(result, "current", "changed"));
});

check(90, "desktop_input_source switches to another layout, reads it back, and desktop_apps agrees", async (s, m) => {
	const list = await m.call("desktop_input_source", {});
	const current = list.data.current;
	const other = (list.data.sources ?? []).find((src) => src.kind === "keyboard_layout" && src.id !== current);
	if (!current || !other) skip("only one keyboard layout is enabled; enable a second (for example U.S.) to run this");
	s.restore.push(async () => m.call("desktop_input_source", { select: current }));
	const result = await m.call("desktop_input_source", { select: other.id });
	const apps = await m.call("desktop_apps", { query: "com.apple.finder" });
	const layout = apps.data.system?.input?.keyboard_layout?.id;
	const back = await m.call("desktop_input_source", { select: current });
	return expect(
		result.outcome === "completed" && dig(result.data, "changed") === true && layout === other.id && back.outcome === "completed",
		`${evidence(result, "current", "changed")}; desktop_apps layout ${layout}; restored ${back.outcome}`,
	);
});

check(90, "desktop_input_source switches to an input method's mode, reads it back, and restores the layout", async (s, m) => {
	const list = await m.call("desktop_input_source", {});
	const current = list.data.current;
	const mode = (list.data.sources ?? []).find((src) => src.kind === "input_mode" && src.id !== current);
	if (!current || !mode) skip("no input method mode is enabled; add one (for example Japanese) to run this");
	s.restore.push(async () => m.call("desktop_input_source", { select: current }));
	const result = await m.call("desktop_input_source", { select: mode.id });
	// An input method types through a layout of its own choosing, which desktop_key and desktop_apps both report.
	const layout = dig(result.data, "keyboard_layout");
	const apps = await m.call("desktop_apps", { query: "com.apple.finder" });
	const reported = apps.data.system?.input?.keyboard_layout?.id;
	const back = await m.call("desktop_input_source", { select: current });
	return expect(
		result.outcome === "completed" && dig(result.data, "current") === mode.id && layout && reported === layout
			&& back.outcome === "completed" && dig(back.data, "current") === current,
		`${evidence(result, "current", "keyboard_layout")}; desktop_apps layout ${reported}; restored ${evidence(back, "current")}`,
	);
});

check(89, "expect: a condition that already holds is refused and no key is sent", async (s, m) => {
	const win = await s.textedit("plain");
	const { snap } = await s.inspect(win);
	const apps = await m.call("desktop_apps", { query: TEXTEDIT });
	const front = apps.data.system?.focus?.bundle_id ?? skip("no frontmost app reported");
	const result = await m.call("desktop_key", { snapshot: snap, key: "right", expect: { until: "app_frontmost", bundle_id: front } });
	return expect(result.outcome === "refused", `front ${front}; ${evidence(result, "expectation")}`);
});

check(89, "expect: a condition that never holds stays unknown, input sent once", async (s, m) => {
	await s.textedit("plain");
	// Background keys come back completed and expect leaves those alone, so this needs input macOS can't confirm:
	// a system key. F19 has no default binding.
	const result = await m.call("desktop_system_key", {
		key: "f19",
		expect: { until: "window_appears", bundle_id: TEXTEDIT, title_contains: `never-${run}`, timeout_ms: 1000 },
	});
	const exp = dig(result.data, "expectation");
	return expect(result.outcome === "unknown" && exp && exp.status !== "matched", evidence(result, "native_outcome", "expectation"));
});

check(89, "expect: Command-Space with window_appears for Spotlight completes (foreground system key)", async (s, m) => {
	// macOS 27 hosts Spotlight in Siri AI (com.apple.campo); earlier releases in com.apple.Spotlight.
	let host = null;
	for (const bundleId of ["com.apple.campo", "com.apple.Spotlight"]) {
		if (await s.runningTarget(bundleId)) {
			host = bundleId;
			break;
		}
	}
	if (!host) skip("no Spotlight host app is running");
	const result = await m.call("desktop_system_key", {
		key: "space",
		modifiers: ["command"],
		expect: { until: "window_appears", bundle_id: host, timeout_ms: 3000 },
	});
	const exp = dig(result.data, "expectation");
	// Escape goes to the frontmost app, so send it only when Spotlight was seen open.
	if (exp?.status === "matched") {
		await sleep(300);
		await m.call("desktop_system_key", { key: "escape" });
	}
	return expect(
		result.outcome === "completed" && exp?.status === "matched",
		`${host}: ${evidence(result, "native_outcome", "expectation")}${exp?.status === "matched" ? "; dismissed with escape" : ""}`,
	);
});

// 0.9.0
check(92, "desktop_set_cell refuses Finder's Name column before input, since Finder wouldn't rename the file", async (s, m) => {
	const { win, snap, outline, table } = await finderTable(s);
	const row = (table?.rows ?? []).find((r) => r.cells?.[0] === "item-08.txt" && r.element) ?? skip("item-08.txt row has no ID");
	const name = `renamed-${run}.txt`;
	const result = await m.call("desktop_set_cell", {
		pid: win.pid, window: win.window, snapshot: snap, table: outline.id, row: row.element, column: "Name", value: name,
	});
	await sleep(500);
	const kept = existsSync(join(s.fixtures.folder, "item-08.txt")) && !existsSync(join(s.fixtures.folder, name));
	return expect(
		result.outcome === "refused" && /CELL_NOT_EDITABLE/.test(result.text) && kept,
		`${evidence(result)}; file on disk ${kept ? "unchanged" : "changed"}`,
	);
}, "Finder shows a name written through Accessibility but never renames the file, so the write is refused.");

check(92, "desktop_set_cell writes a focused web grid input and refuses an unfocused one", async (s, m) => {
	const win = await s.web();
	const first = await s.inspect(win);
	const input = findOrSkip(first.els, "AXTextField", /Note one/, "grid input");
	await m.call("desktop_click", { snapshot: first.snap, element: input.id });
	const { snap, els } = await s.inspect(win);
	const grid = find(els, "AXTable", /Edit grid/) ?? find(els, "AXGrid") ?? skip("grid table not in the inspection");
	const read = await s.read(win, { scope: { snapshot: snap, element: grid.id }, table: true });
	const rows = tableOf(read)?.rows ?? [];
	const one = rows.find((r) => r.cells?.[0] === "Row one" && r.element) ?? skip("grid row one has no ID");
	const two = rows.find((r) => r.cells?.[0] === "Row two" && r.element);
	const written = await m.call("desktop_set_cell", {
		pid: win.pid, window: win.window, snapshot: snap, table: grid.id, row: one.element, column: "Note", value: `gamma ${run}`,
	});
	const unfocused = two
		? await m.call("desktop_set_cell", {
				pid: win.pid, window: win.window, snapshot: snap, table: grid.id, row: two.element, column: "Note", value: "delta",
			})
		: null;
	return expect(
		written.outcome === "completed" && (!unfocused || unfocused.outcome === "refused"),
		`focused: ${evidence(written, "readback")}; unfocused: ${unfocused ? evidence(unfocused, "hint") : "row two had no ID"}`,
	);
});

check(88, "desktop_select selects a phrase in a Safari paragraph, and Edit > Copy in the activated Safari copies exactly it", async (s, m) => {
	await s.clipboard();
	const win = await s.web();
	const { snap, els } = await s.inspect(win);
	const prose = els.find((e) => /quick brown fox/.test(`${label(e)} ${e.value ?? ""}`)) ?? skip("paragraph text not in the inspection");
	const result = await m.call("desktop_select", { snapshot: snap, element: prose.id, text: "brown fox jumps" });
	if (result.outcome !== "completed") return expect(false, evidence(result, "selection"));
	// Safari disables Copy in the background; selecting focused the page, so Copy doesn't take the address field.
	const safari = (await m.call("desktop_apps", { query: "Safari" })).data.apps?.find((a) => a.target?.pid === win.pid)
		?? skip("Safari not in desktop_apps");
	await m.call("desktop_activate", { target: safari.target });
	const copy = await m.call("desktop_menu", { target: safari.target, path: ["Edit", "Copy"] });
	await sleep(300);
	const clip = await m.call("desktop_clipboard_read", { format: "text" });
	return expect(
		clip.data.text === "brown fox jumps",
		`${evidence(result, "selection")}; Edit > Copy ${evidence(copy)}; clipboard ${brief(clip.data.text, 60)}`,
	);
}, "Brings Safari to the front for the copy.");

check(88, "desktop_select selects a link's text", async (s, m) => {
	const win = await s.web();
	const { snap, els } = await s.inspect(win);
	const link = find(els, "AXLink", /riverbank/) ?? skip("link not in the inspection");
	const result = await m.call("desktop_select", { snapshot: snap, element: link.id, text: "riverbank" });
	return expect(result.outcome === "completed", evidence(result, "selection"));
});

check(86, "Finder list view table read has Name and Kind columns and the folder's rows", async (s) => {
	const { read, table } = await finderTable(s);
	const columns = table?.columns ?? [];
	const names = (table?.rows ?? []).map((r) => r.cells?.[0]);
	return expect(
		columns.includes("Name") && names.includes("item-01.txt") && names.includes("sub-folder"),
		`columns ${brief(columns)}; ${names.length} rows; ${read.isError ? brief(read.text) : `depth on rows: ${(table?.rows ?? []).some((r) => "depth" in r)}`}`,
	);
});

check(86, "Safari table read takes <th> as columns and drops the header row", async (s) => {
	const win = await s.web();
	const { snap, els } = await s.inspect(win);
	const table = find(els, "AXTable", /Fruit/) ?? skip("fruit table not in the inspection");
	const read = await s.read(win, { scope: { snapshot: snap, element: table.id }, table: true });
	const t = tableOf(read);
	const rows = (t?.rows ?? []).map((r) => r.cells?.[0]);
	return expect(
		JSON.stringify(t?.columns) === JSON.stringify(["Fruit", "Count"]) && rows.join() === "Apple,Pear,Plum",
		`columns ${brief(t?.columns)}; rows ${brief(rows)}`,
	);
});

// 0.8.0
check(83, "desktop_apps reports system state: unlocked session, focus and keyboard layout", async (s, m) => {
	const { data } = await m.call("desktop_apps", { query: FINDER });
	const sys = data.system ?? {};
	const sources = await m.call("desktop_input_source", {});
	const layout = sys.input?.keyboard_layout?.id;
	return expect(
		// Compact results leave out the session's false fields, so an unlocked session has no locked field.
		sys.session && sys.session.locked !== true && sys.focus?.pid > 0 && layout && layout === sources.data.keyboard_layout,
		`locked ${sys.session?.locked}; focus ${sys.focus?.app_name}; layout ${layout} vs input source ${sources.data.keyboard_layout}`,
	);
});

check(82, "desktop_type into a focused React-style controlled web input updates page state", async (s, m) => {
	const win = await s.web();
	const first = await s.inspect(win);
	const field = findOrSkip(first.els, "AXTextField", /Controlled field/, "controlled field");
	await m.call("desktop_click", { snapshot: first.snap, element: field.id });
	const { snap, els } = await s.inspect(win);
	const focused = findOrSkip(els, "AXTextField", /Controlled field/, "controlled field");
	const text = `hello ${run}`;
	const result = await m.call("desktop_type", { snapshot: snap, element: focused.id, text });
	await sleep(300);
	const page = await s.read(win);
	const state = page.text.includes(`state:${text}`);
	return expect(result.outcome === "completed" && state, `${evidence(result, "readback", "value")}; page state ${state ? "updated" : "not updated"}`);
});

check(82, "desktop_type into an unfocused web input is refused with the click hint", async (s, m) => {
	const win = await s.web();
	const { snap, els } = await s.inspect(win);
	const other = findOrSkip(els, "AXTextField", /Other field/, "other field");
	if (other.attributes?.isFocused === "true") skip("the other field already has focus");
	const result = await m.call("desktop_type", { snapshot: snap, element: other.id, text: "nope" });
	return expect(result.outcome === "refused" && /click/i.test(result.text), evidence(result, "hint"));
});

check(82, "desktop_type into a native TextEdit text area still completes with readback", async (s, m) => {
	const win = await s.textedit("plain");
	const { snap, els } = await s.inspect(win);
	const area = findOrSkip(els, "AXTextArea", null, "text area");
	const text = `Typed by live check ${run}.`;
	const result = await m.call("desktop_type", { snapshot: snap, element: area.id, text });
	const page = await s.read(win);
	return expect(result.outcome === "completed" && page.text.includes(text), evidence(result, "value"));
});

check(81, "desktop_inspect save_path writes the full-resolution PNG", async (s, m) => {
	const win = await s.textedit("plain");
	const out = join(s.fixtures.captures, "inspect.png");
	const { result } = await s.inspect(win, { save_path: out });
	const saved = result.data.saved;
	const size = existsSync(out) ? pngSize(out) : null;
	return expect(
		saved?.path === out && size && size.width === saved.width && size.height === saved.height && size.width >= win.info.bounds.width,
		`saved ${brief(saved)}; file ${brief(size)}; window ${win.info.bounds.width}×${win.info.bounds.height} pt`,
	);
});

check(81, "save_path refuses an existing file without overwrite, before capturing", async (s, m) => {
	const win = await s.textedit("plain");
	const out = join(s.fixtures.captures, "existing.png");
	writeFileSync(out, "keep");
	const result = await m.call("desktop_inspect", { pid: win.pid, window: win.window, save_path: out });
	return expect(result.isError && readFileSync(out, "utf8") === "keep", `${brief(result.text, 160)}; file ${readFileSync(out, "utf8") === "keep" ? "kept" : "replaced"}`);
});

check(81, "desktop_screen save_path with region saves only that part", async (s, m) => {
	const win = await s.textedit("plain");
	const out = join(s.fixtures.captures, "region.png");
	const b = win.info.bounds;
	const region = { x: b.x + 10, y: b.y + 10, width: 200, height: 100 };
	const result = await m.call("desktop_screen", { display: win.info.display_index ?? 0, save_path: out, region });
	const size = existsSync(out) ? pngSize(out) : null;
	const scale = size ? size.width / 200 : 0;
	return expect(
		size && Number.isInteger(scale) && scale >= 1 && size.height === 100 * scale,
		`saved ${brief(result.data.saved)}; file ${brief(size)} for a 200×100 pt region`,
	);
});

check(79, "desktop_set_value sets a web date input to an ISO 8601 date, or refuses an unsettable one before input", async (s, m) => {
	const win = await s.web();
	const { snap, els } = await s.inspect(win);
	const date = els.find((e) => /Date field/.test(label(e))) ?? skip("date input not in the inspection");
	// Not today's date, which an empty date input already shows.
	const result = await m.call("desktop_set_value", { snapshot: snap, element: date.id, value: "2026-03-04" });
	await sleep(300);
	const page = await s.read(win);
	const changed = page.text.includes("date:2026-03-04");
	// Safari on macOS 27 reports its date input's value as not settable: a refusal naming the keyboard route is right.
	const refused = result.outcome === "refused" && /no settable value/.test(result.text) && /keyboard/.test(result.text) && !changed;
	return expect(
		(result.outcome === "completed" && changed) || refused,
		`${evidence(result, "value", "readback")}; role ${date.attributes?.role ?? date.role}; page ${changed ? "saw the input event" : "did not see an input event"}`,
	);
});

check(77, "desktop_click refuses control modifiers and right-click with modifiers, before input", async (s, m) => {
	const win = await s.textedit("plain");
	const { snap, els } = await s.inspect(win);
	const area = findOrSkip(els, "AXTextArea", null, "text area");
	const control = await m.call("desktop_click", { snapshot: snap, element: area.id, modifiers: ["control"] });
	const fresh = await s.inspect(win);
	const right = await m.call("desktop_click", { snapshot: fresh.snap, element: area.id, kind: "right", modifiers: ["shift"] });
	const refused = (r) => r.outcome === "refused" || (r.isError && !r.outcome);
	return expect(refused(control) && refused(right), `control: ${evidence(control)}; right+shift: ${evidence(right)}`);
});

check(77, "Command-click selects a second Finder row (foreground modifier click)", async (s, m) => {
	const first = await finderTable(s);
	const a = first.table?.rows?.find((r) => r.cells?.[0] === "item-01.txt" && r.element) ?? skip("item-01.txt row has no ID");
	await m.call("desktop_click", { snapshot: first.snap, element: a.element });
	const second = await finderTable(s);
	const c = second.table?.rows?.find((r) => r.cells?.[0] === "item-03.txt" && r.element) ?? skip("item-03.txt row has no ID");
	const result = await m.call("desktop_click", { snapshot: second.snap, element: c.element, modifiers: ["command"] });
	await sleep(300);
	const after = await finderTable(s);
	const selected = selectedNames(after.table);
	return expect(
		selected.includes("item-01.txt") && selected.includes("item-03.txt") && selected.length === 2,
		`${evidence(result, "cursor_restoration", "focus_restoration")}; selected ${brief(selected)}`,
	);
});

check(77, "Shift-click selects a range of Finder rows", async (s, m) => {
	const first = await finderTable(s);
	const a = first.table?.rows?.find((r) => r.cells?.[0] === "item-01.txt" && r.element) ?? skip("item-01.txt row has no ID");
	await m.call("desktop_click", { snapshot: first.snap, element: a.element });
	const second = await finderTable(s);
	const e = second.table?.rows?.find((r) => r.cells?.[0] === "item-04.txt" && r.element) ?? skip("item-04.txt row has no ID");
	const result = await m.call("desktop_click", { snapshot: second.snap, element: e.element, modifiers: ["shift"] });
	await sleep(300);
	const selected = selectedNames((await finderTable(s)).table);
	const want = ["item-01.txt", "item-02.txt", "item-03.txt", "item-04.txt"];
	return expect(want.every((n) => selected.includes(n)) && selected.length === 4, `${evidence(result)}; selected ${brief(selected)}`);
});

check(77, "desktop_key repeat 5 of down moves the Finder selection five rows", async (s, m) => {
	const first = await finderTable(s);
	const rows = first.table?.rows ?? [];
	const a = rows.find((r) => r.element) ?? skip("no row IDs");
	await m.call("desktop_click", { snapshot: first.snap, element: a.element });
	const second = await finderTable(s);
	const start = second.table.rows.findIndex((r) => r.selected);
	const result = await m.call("desktop_key", { snapshot: second.snap, key: "down", repeat: 5 });
	await sleep(300);
	const end = (await finderTable(s)).table.rows.findIndex((r) => r.selected);
	return expect(end - start === 5, `${evidence(result, "keys_sent", "keys_requested")}; selected row ${start} → ${end}`);
});

check(77, "desktop_key sequence sends every key: right, right, Command-A", async (s, m) => {
	const win = await s.textedit("plain");
	const { snap } = await s.inspect(win);
	const result = await m.call("desktop_key", { snapshot: snap, keys: [{ key: "right" }, { key: "right" }, { key: "a", modifiers: ["command"] }] });
	const act = action(result);
	return expect(
		result.outcome === "completed" && dig(act, "keys_sent") === 3 && dig(act, "keys_requested") === 3,
		evidence(result, "keys_sent", "keys_requested"),
	);
});

check(77, "a key sequence stops with KEY_SEQUENCE_STOPPED when a key opens another window", async (s, m) => {
	const win = await s.textedit("plain");
	const beforeIds = new Set((await s.windows(win.pid)).map((w) => w.window_id));
	const { snap } = await s.inspect(win);
	try {
		const result = await m.call("desktop_key", { snapshot: snap, keys: [{ key: "n", modifiers: ["command"] }, { key: "x" }, { key: "y" }] });
		await sleep(500);
		const act = action(result);
		return expect(
			result.outcome === "unknown" && /KEY_SEQUENCE_STOPPED/.test(result.text) && dig(act, "keys_sent") < 3,
			evidence(result, "keys_sent", "keys_requested"),
		);
	} finally {
		await s.adopt(win.pid, beforeIds, "TextEdit untitled window from Command-N");
	}
});

check(70, "desktop_wait text_contains matches text typed into TextEdit", async (s, m) => {
	const win = await s.textedit("rich");
	const { snap, els } = await s.inspect(win);
	const area = findOrSkip(els, "AXTextArea", null, "text area");
	const text = `wait marker ${run}`;
	await m.call("desktop_type", { snapshot: snap, element: area.id, text });
	const result = await m.call("desktop_wait", { until: "text_contains", pid: win.pid, window: win.window, text, timeout_ms: 5000 });
	return expect(result.outcome === "completed" || dig(result.data, "matched") === true || /matched/.test(result.text), brief(result.text, 200));
});

// Last, since it can leave a prompt open that only the user may answer, and every input waits for that answer.
check(120, "a caller the user hasn't allowed is refused, and input waits while its prompt is open", async (s, m) => {
	approvesCallers();
	const win = await s.textedit("plain");
	// perl stays the server's parent, so the host sees /usr/bin/perl as the caller. The block form never splits a
	// --server path with spaces, as one-argument system does.
	const perl = new Mcp(["/usr/bin/perl", "-e", "system { $ARGV[0] } @ARGV; exit($? >> 8)"]);
	try {
		await perl.start();
		const apps = await perl.call("desktop_apps", {});
		if (!apps.isError) skip("the user allowed /usr/bin/perl; choose Forget under Approved Agents to run this check");
		const refused = /CALLER_NOT_APPROVED/.test(apps.text);
		if (!/hasn't approved/.test(apps.text)) return expect(refused, `perl was refused before (denied): ${brief(apps.text, 160)}`);
		const focus = await m.call("desktop_focus", { target: win.info.target });
		const own = focus.outcome === "refused" && /SELF_TARGET_REFUSED/.test(focus.text);
		console.log("       Desktop Tools is asking whether perl may control this Mac: choose Don't Allow. Waiting up to 2 minutes.");
		let answered = false;
		for (let i = 0; i < 60 && !answered; i++) {
			await sleep(2000);
			const again = await perl.call("desktop_apps", {});
			answered = !again.isError || !/hasn't approved/.test(again.text);
		}
		return expect(
			refused && own && answered,
			`perl refused ${refused}; focus while the prompt was open ${evidence(focus)}; prompt answered ${answered}`,
		);
	} finally {
		perl.stop();
	}
}, "Runs a second MCP server under /usr/bin/perl, which the host asks the user about once; it waits for the user to answer that prompt. Choose Don't Allow, so later runs only check the refusal.");

// ---------- runner ----------

async function main() {
	const results = [];
	const log = (line) => console.log(`  · ${line}`);
	const selected = checks.filter((c) => only.size === 0 || only.has(c.pr));
	if (values.list) {
		for (const c of selected) console.log(`#${c.pr}  ${c.title}`);
		return 0;
	}
	if (selected.length === 0) {
		console.error(`No automated checks for ${[...only].map((p) => `#${p}`).join(", ")}; see docs/live-checks.md.`);
		return 2;
	}
	const mcp = new Mcp();
	await mcp.start();
	const { data, text, isError } = await mcp.call("desktop_apps", { query: FINDER });
	if (isError && /CALLER_NOT_APPROVED/.test(text)) {
		console.error(`Desktop Tools hasn't allowed the program that ran this harness, such as your terminal or agent. Choose Allow in its prompt or under Approved Agents in its menu, then run again. ${brief(text, 300)}`);
		mcp.stop();
		return 2;
	}
	const session = data.system?.session;
	if (!session) {
		console.error(`desktop_apps did not report the session; is Desktop Tools running? ${brief(JSON.stringify(data), 300)}`);
		mcp.stop();
		return 2;
	}
	if (session.locked || !session.on_console || session.screensaver_running || session.displays_asleep) {
		console.error(`Refusing to run: the screen is locked or not on the console (${JSON.stringify(session)}). Nothing was opened.`);
		mcp.stop();
		return 2;
	}

	const fixtures = makeFixtures();
	const s = new Session(mcp, fixtures);
	// The clipboard is the user's: checks that touch it run only when it holds plain text, which is put back at the end.
	let clipboard;
	s.clipboard = async () => {
		if (!clipboard) {
			const read = await mcp.call("desktop_clipboard_read", { format: "text" });
			clipboard = read.isError || (read.data.present && typeof read.data.text !== "string")
				? { skip: `the clipboard holds something other than plain text, which the harness can't put back (${brief(read.text, 120)})` }
				: { text: read.data.text ?? "" };
			if (!clipboard.skip) s.restore.unshift(async () => mcp.call("desktop_clipboard_write", { text: clipboard.text }));
		}
		if (clipboard.skip) skip(clipboard.skip);
	};
	let interrupted = false;
	const stop = () => {
		interrupted = true;
	};
	process.once("SIGINT", stop);
	process.once("SIGTERM", stop);

	try {
		for (const c of selected) {
			if (interrupted) break;
			const started = Date.now();
			let outcome;
			try {
				outcome = await c.run(s, mcp);
			} catch (error) {
				outcome = error instanceof Skip
					? { status: "skip", detail: error.message }
					: { status: "fail", detail: `error: ${error.message}` };
			}
			const row = { pr: c.pr, title: c.title, ...outcome, ms: Date.now() - started, notes: c.notes };
			results.push(row);
			console.log(`${row.status.toUpperCase().padEnd(4)} #${c.pr} ${c.title}\n       ${row.detail}`);
		}
	} finally {
		console.log("\nCleanup:");
		await s.cleanup(log);
		if (values["keep-fixtures"]) log(`fixtures kept in ${fixtures.root}`);
		else rmSync(fixtures.root, { recursive: true, force: true });
		mcp.stop();
	}

	console.log("\nSummary by PR:");
	const byPr = new Map();
	for (const r of results) byPr.set(r.pr, [...(byPr.get(r.pr) ?? []), r]);
	for (const [pr, rows] of [...byPr].sort((a, b) => Number(b[0]) - Number(a[0]))) {
		const count = (status) => rows.filter((r) => r.status === status).length;
		console.log(`  #${pr}: ${count("pass")} pass, ${count("fail")} fail, ${count("skip")} skip`);
	}
	console.log("Checks that stay manual are listed in docs/live-checks.md.");
	if (values.json) writeFileSync(values.json, `${JSON.stringify({ run, results }, null, 2)}\n`);
	if (interrupted) return 130;
	return results.some((r) => r.status === "fail") ? 1 : 0;
}

process.exitCode = await main();
