import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { createDesktop } from "../dist/client.js";

const macOS = { skip: process.platform !== "darwin" && "the client runs only on macOS" };
const signal = new AbortController().signal;

/** A native client whose key action reports delivery with the given app state. */
function fakeClient(app) {
	const directory = mkdtempSync(join(tmpdir(), "desktop-tools-keys-"));
	const client = join(directory, "client");
	writeFileSync(join(directory, "socket"), "");
	const action = {
		outcome: "completed", action: "key", snapshot_id: "S1", receiver: "observed_control",
		requires_fresh_observation: true, ...app,
	};
	writeFileSync(client, `#!/usr/bin/env node
const command = process.argv[3];
const reply = command === "action"
	? { success: true, data: ${JSON.stringify(action)}, target_receipt: { pid: 1, window_id: 2 } }
	: { success: false, error: { code: "DESKTOP_ERROR", message: "not observed" } };
process.stdout.write(JSON.stringify(reply));
process.exit(reply.success ? 0 : 1);
`);
	chmodSync(client, 0o755);
	const desktop = createDesktop({ client, socket: join(directory, "socket"), name: "test" });
	return { desktop, done: () => rmSync(directory, { recursive: true, force: true }) };
}

async function press(app, request = { key: "down" }) {
	const { desktop, done } = fakeClient(app);
	try {
		const result = await desktop({ op: "key", snapshot: "S1", ...request }, signal);
		return { outcome: result.outcome, action: JSON.parse(result.text).action };
	} finally {
		done();
	}
}

test("keys delivered to a background Chromium app are unknown, with a hint to activate it", macOS, async () => {
	for (const request of [{ key: "down" }, { key: "down", repeat: 3 }, { keys: [{ key: "down" }, { key: "enter" }] }]) {
		const { outcome, action } = await press({ app_active: false, app_ships_chromium: true }, request);
		assert.equal(outcome, "unknown", JSON.stringify(request));
		assert.equal(action.outcome, "unknown");
		assert.equal(action.error.code, "KEYS_TO_BACKGROUND_CHROMIUM");
		assert.match(action.error.hint, /desktop_activate/);
	}
});

test("keys to an active Chromium app or a background native app keep their outcome", macOS, async () => {
	for (const app of [
		{ app_active: true, app_ships_chromium: true },
		{ app_active: false, app_ships_chromium: false },
		{},
	]) {
		const { outcome, action } = await press(app);
		assert.equal(outcome, "completed", JSON.stringify(app));
		assert.equal(action.error, undefined);
	}
});
