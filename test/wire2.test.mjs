import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { createDesktop } from "../dist/client.js";

const macOS = { skip: process.platform !== "darwin" && "the client runs only on macOS" };
const signal = new AbortController().signal;

/**
 * A native2 client in --serve mode that answers each request line with `reply`, or with `reply(request, argv, agent)`
 * when it's a function, run through createDesktop's wire 2. The function runs in the client process, so it can't close
 * over anything; it returns { result } or { error } to tag with the request's id, { untagged } to write as is, or
 * undefined to answer nothing. A cancel line reaches it as a request too.
 */
function wire2(reply, options = {}) {
	const directory = mkdtempSync(join(tmpdir(), "desktop-tools-wire2-"));
	const client = join(directory, "client");
	writeFileSync(client, `#!/usr/bin/env node
const reply = ${typeof reply === "function" ? reply.toString() : `() => (${JSON.stringify(reply)})`};
require("node:readline").createInterface({ input: process.stdin }).on("line", (line) => {
	const request = JSON.parse(line);
	const answer = reply(request, process.argv.slice(2), process.env.DESKTOP_TOOLS_AGENT);
	if (answer === undefined) return;
	process.stdout.write(JSON.stringify(answer.untagged ?? { id: request.id, ...answer }) + "\\n");
	if (answer.untagged) process.exit(1);
});
`);
	chmodSync(client, 0o755);
	const desktop = createDesktop({ client, socket: join(directory, "socket"), name: "Desktop Tools", wire: 2, ...options });
	return { desktop, done: () => rmSync(directory, { recursive: true, force: true }) };
}

const text = (value) => ({ type: "text", text: typeof value === "string" ? value : JSON.stringify(value) });

test("wire 2 sends the request as its tool, with the other fields as arguments", macOS, async () => {
	const { desktop, done } = wire2(
		(request, argv, agent) => ({ result: { content: [{ type: "text", text: JSON.stringify({ request, argv, agent }) }] } }),
		{ agent: "Claude" },
	);
	try {
		const result = await desktop({ op: "menubar-items" }, signal);
		assert.deepEqual(result.data.argv.slice(1), ["--serve"]);
		assert.equal(result.data.request.tool, "desktop_menubar_items");
		assert.deepEqual(result.data.request.arguments, {});
		assert.equal(result.data.agent, "Claude");
		const windows = await desktop({ op: "windows", pid: 7, all: true }, signal);
		assert.equal(windows.data.request.tool, "desktop_windows");
		assert.deepEqual(windows.data.request.arguments, { pid: 7, all: true });
	} finally {
		done();
	}
});

test("wire 2 asks for the full result when verbose", macOS, async () => {
	const { desktop, done } = wire2((request) => ({ result: { content: [{ type: "text", text: JSON.stringify(request) }] } }), { verbose: true });
	try {
		const result = await desktop({ op: "apps" }, signal);
		assert.equal(result.data.verbose, true);
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
		const { desktop, done } = wire2({ untagged: { error: { code, message: "x" } } });
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

test("wire 2 keeps one client for every call, and calls overlap", macOS, async () => {
	// The first call is answered only after the second arrives, so they must overlap in one process.
	const { desktop, done } = wire2((request) => {
		globalThis.held ??= [];
		const answer = { id: request.id, result: { content: [{ type: "text", text: JSON.stringify({ pid: process.pid }) }] } };
		if (globalThis.held.push(answer) < 2) return undefined;
		for (const held of globalThis.held.reverse()) process.stdout.write(JSON.stringify(held) + "\n");
		globalThis.held = [];
		return undefined;
	});
	try {
		const [first, second] = await Promise.all([desktop({ op: "apps" }, signal), desktop({ op: "spaces" }, signal)]);
		assert.equal(first.data.pid, second.data.pid);
	} finally {
		done();
	}
});

test("wire 2 ends waiting calls when the client exits, and starts another for the next call", macOS, async () => {
	const { desktop, done } = wire2((request) => request.tool === "desktop_quit"
		? process.exit(3)
		: { result: { content: [{ type: "text", text: JSON.stringify({ pid: process.pid }) }] } });
	try {
		const before = await desktop({ op: "apps" }, signal);
		await assert.rejects(desktop({ op: "quit", target: { pid: 1 } }, signal), { message: /exited with status 3/ });
		const after = await desktop({ op: "apps" }, signal);
		assert.notEqual(before.data.pid, after.data.pid);
	} finally {
		done();
	}
});

test("wire 2 cancels an aborted call through the client and stops waiting", macOS, async () => {
	// The client answers a cancel by reporting it on the next call.
	const { desktop, done } = wire2((request) => {
		if (request.tool === "desktop_wait") return undefined;
		if ("cancel" in request) { globalThis.cancelled = request.cancel; return undefined; }
		return { result: { content: [{ type: "text", text: JSON.stringify({ cancelled: globalThis.cancelled ?? null }) }] } };
	});
	try {
		const abort = new AbortController();
		const waiting = desktop({ op: "wait", timeout_ms: 1000 }, abort.signal);
		abort.abort(new Error("stopped"));
		await assert.rejects(waiting, { message: "stopped" });
		const result = await desktop({ op: "apps" }, signal);
		assert.equal(result.data.cancelled, 1);
	} finally {
		done();
	}
});
