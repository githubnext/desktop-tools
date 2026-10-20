import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { createDesktop } from "../dist/client.js";

const macOS = { skip: process.platform !== "darwin" && "the client runs only on macOS" };
const signal = new AbortController().signal;

/**
 * A native2 client that replies with `reply`, or with `reply(argv, arguments, agent)` when it's a function, run through
 * createDesktop's wire 2. The function runs in the client process, so it can't close over anything.
 */
function wire2(reply, options = {}) {
	const directory = mkdtempSync(join(tmpdir(), "desktop-tools-wire2-"));
	const client = join(directory, "client");
	writeFileSync(client, `#!/usr/bin/env node
const input = require("node:fs").readFileSync(0, "utf8");
const reply = (${typeof reply === "function" ? reply.toString() : `() => (${JSON.stringify(reply)})`})(
	process.argv.slice(2), JSON.parse(input), process.env.DESKTOP_TOOLS_AGENT);
process.stdout.write(JSON.stringify(reply));
process.exit(reply.error ? 1 : 0);
`);
	chmodSync(client, 0o755);
	const desktop = createDesktop({ client, socket: join(directory, "socket"), name: "Desktop Tools", wire: 2, ...options });
	return { desktop, done: () => rmSync(directory, { recursive: true, force: true }) };
}

const text = (value) => ({ type: "text", text: typeof value === "string" ? value : JSON.stringify(value) });

test("wire 2 sends the request as its tool, with the other fields as arguments", macOS, async () => {
	const { desktop, done } = wire2(
		(argv, args, agent) => ({ result: { content: [{ type: "text", text: JSON.stringify({ argv, args, agent }) }] } }),
		{ agent: "Claude" },
	);
	try {
		const result = await desktop({ op: "menubar-items" }, signal);
		assert.deepEqual(result.data.argv.slice(1), ["desktop_menubar_items"]);
		assert.deepEqual(result.data.args, {});
		assert.equal(result.data.agent, "Claude");
		const windows = await desktop({ op: "windows", pid: 7, all: true }, signal);
		assert.deepEqual(windows.data.argv.slice(1), ["desktop_windows"]);
		assert.deepEqual(windows.data.args, { pid: 7, all: true });
	} finally {
		done();
	}
});

test("wire 2 asks for the full result when verbose", macOS, async () => {
	const { desktop, done } = wire2((argv) => ({ result: { content: [{ type: "text", text: JSON.stringify(argv) }] } }), { verbose: true });
	try {
		const result = await desktop({ op: "apps" }, signal);
		assert.deepEqual(result.data.slice(1), ["desktop_apps", "--verbose"]);
	} finally {
		done();
	}
});

test("wire 2 reads an action's outcome, its image and isError from the tool result", macOS, async () => {
	const action = { action: { outcome: "refused", reason: "stale" } };
	const { desktop, done } = wire2({ result: { isError: true, content: [
		text("Outcome: refused."), text(action), { type: "image", data: "AAAA", mimeType: "image/jpeg" },
	] } });
	try {
		const result = await desktop({ op: "click", snapshot: "ps1_00", element: "elem_1" }, signal);
		assert.equal(result.outcome, "refused");
		assert.equal(result.isError, true);
		assert.deepEqual(result.data, action);
		assert.deepEqual(result.image, { data: "AAAA", mimeType: "image/jpeg" });
	} finally {
		done();
	}
});

test("wire 2 throws a plain error text, as the MCP server reports a thrown error", macOS, async () => {
	const { desktop, done } = wire2({ result: { isError: true, content: [text("Choose all true or false.")] } });
	try {
		await assert.rejects(desktop({ op: "windows", pid: 1, all: "x" }, signal), { message: "Choose all true or false." });
	} finally {
		done();
	}
});

test("wire 2 names the host app when no host serves the socket", macOS, async () => {
	for (const [code, hint] of [["HOST_NOT_RUNNING", "Ask the user to open Desktop Tools."], ["HOST_NOT_SERVING", "Ask the user to check"]]) {
		const { desktop, done } = wire2({ error: { code, message: "x" } });
		try {
			await assert.rejects(desktop({ op: "apps" }, signal), (error) => {
				assert.match(error.message, new RegExp(`^${code}: Desktop Tools isn't serving .*so nothing ran. ${hint}`));
				return true;
			});
		} finally {
			done();
		}
	}
});
