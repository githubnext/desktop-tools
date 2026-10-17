import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { createDesktop } from "../dist/client.js";

const macOS = { skip: process.platform !== "darwin" && "the client runs only on macOS" };
const incomplete = { code: "DESKTOP_ERROR", message: "Warning: AX tree incomplete at incomplete accessibility read" };

/** A native client that fails its first `failures` reads with an incomplete tree, and logs each command. */
function fakeClient(failures) {
	const directory = mkdtempSync(join(tmpdir(), "desktop-tools-retry-"));
	const log = join(directory, "log");
	const client = join(directory, "client");
	writeFileSync(log, "");
	writeFileSync(join(directory, "socket"), "");
	writeFileSync(client, `#!/usr/bin/env node
const { appendFileSync, readFileSync } = require("node:fs");
const command = process.argv[3];
appendFileSync(${JSON.stringify(log)}, command + "\\n");
const reads = readFileSync(${JSON.stringify(log)}, "utf8").split("\\n").filter((line) => line === "read").length;
const reply = command === "read"
	? reads <= ${failures}
		? { success: false, error: ${JSON.stringify(incomplete)} }
		: { success: true, data: { text: "Loaded page", truncated: false }, target_receipt: { pid: 1, window_id: 2 } }
	: { success: true, data: command === "apps" ? { apps: [] } : { windows: [] } };
process.stdout.write(JSON.stringify(reply));
process.exit(reply.success ? 0 : 1);
`);
	chmodSync(client, 0o755);
	const desktop = createDesktop({ client, socket: join(directory, "socket"), name: "test" });
	const reads = () => readFileSync(log, "utf8").split("\n").filter((line) => line === "read").length;
	return { desktop, reads, done: () => rmSync(directory, { recursive: true, force: true }) };
}

const signal = new AbortController().signal;

test("an incomplete Accessibility read is read once more after a second", macOS, async () => {
	const { desktop, reads, done } = fakeClient(1);
	try {
		const started = Date.now();
		const result = await desktop({ op: "read", pid: 1, window: 2 }, signal);
		assert.equal(result.isError, undefined);
		assert.equal(JSON.parse(result.text).text, "Loaded page");
		assert.equal(reads(), 2);
		assert.ok(Date.now() - started >= 900);
	} finally {
		done();
	}
});

test("a second incomplete read returns the error with retried, and isn't read a third time", macOS, async () => {
	const { desktop, reads, done } = fakeClient(2);
	try {
		const result = await desktop({ op: "read", pid: 1, window: 2 }, signal);
		const data = JSON.parse(result.text);
		assert.equal(result.isError, true);
		assert.match(data.read_error.message, /AX tree incomplete/);
		assert.equal(data.retried, true);
		assert.equal(reads(), 2);
	} finally {
		done();
	}
});

test("a read that the caller ends during the wait returns the first failure without retried", macOS, async () => {
	const { desktop, reads, done } = fakeClient(2);
	try {
		const result = await desktop({ op: "read", pid: 1, window: 2 }, AbortSignal.timeout(300));
		const data = JSON.parse(result.text);
		assert.equal(data.retried, undefined);
		assert.equal(reads(), 1);
	} finally {
		done();
	}
});
