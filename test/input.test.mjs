import assert from "node:assert/strict";
import { test } from "node:test";
import { createDesktop } from "../dist/client.js";

// Every request here is refused before the native client would run.
const desktop = createDesktop({ client: "/nonexistent/desktop-client", socket: "/nonexistent/desktop.sock", name: "test" });
const signal = new AbortController().signal;
// The client refuses every request off macOS before validating it.
const macOS = { skip: process.platform !== "darwin" && "the client validates only on macOS" };

async function refusal(request) {
	const result = await desktop({ snapshot: "S1", ...request }, signal);
	assert.equal(result.outcome, "refused", JSON.stringify(request));
	return JSON.parse(result.text).action.reason;
}

test("modifier clicks hold command, option or shift for single, double or triple clicks", macOS, async () => {
	assert.match(await refusal({ op: "click", element: "e1", modifiers: ["control"] }), /kind right/);
	assert.match(await refusal({ op: "click", element: "e1", modifiers: [] }), /kind right/);
	assert.match(await refusal({ op: "click", element: "e1", modifiers: ["shift", "shift"] }), /at most once/);
	assert.match(await refusal({ op: "click", element: "e1", kind: "right", modifiers: ["command"] }), /single, double, or triple/);
	assert.match(await refusal({ op: "click", element: "e1", kind: "middle", modifiers: ["option"] }), /single, double, or triple/);
});

test("key sequences take 1 to 16 chords, or one key repeated up to 32 times", macOS, async () => {
	const tab = { key: "tab" };
	assert.match(await refusal({ op: "key" }), /one key, or a sequence/);
	assert.match(await refusal({ op: "key", key: "tab", keys: [tab] }), /one key, or a sequence/);
	assert.match(await refusal({ op: "key", keys: [] }), /1 to 16 keys/);
	assert.match(await refusal({ op: "key", keys: Array(17).fill(tab) }), /1 to 16 keys/);
	assert.match(await refusal({ op: "key", keys: [tab], repeat: 2 }), /1 to 16 keys/);
	assert.match(await refusal({ op: "key", keys: [tab], modifiers: ["shift"] }), /1 to 16 keys/);
	assert.match(await refusal({ op: "key", keys: [{ key: "tab", text: "x" }] }), /key and optional modifiers/);
	assert.match(await refusal({ op: "key", keys: [tab, { key: "nope" }] }), /named key/);
	assert.match(await refusal({ op: "key", key: "down", repeat: 33 }), /1 to 32/);
	assert.match(await refusal({ op: "key", key: "down", repeat: 0 }), /1 to 32/);
	assert.match(await refusal({ op: "key", key: "down", repeat: 1.5 }), /1 to 32/);
});
