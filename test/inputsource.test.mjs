import assert from "node:assert/strict";
import { test } from "node:test";
import { createDesktop } from "../dist/client.js";
import { desktopTools } from "../dist/tools.js";

// Every request here is refused before the native client would run.
const desktop = createDesktop({ client: "/nonexistent/desktop-client", socket: "/nonexistent/desktop.sock", name: "test" });
const signal = new AbortController().signal;
// The client refuses every request off macOS before validating it.
const macOS = { skip: process.platform !== "darwin" && "the client validates only on macOS" };

test("selecting takes one input source id and nothing else", macOS, async () => {
	for (const select of ["", "com.apple.keylayout.US\n", "with space", "x".repeat(257), 7]) {
		const result = await desktop({ op: "input-source", select }, signal);
		assert.equal(result.outcome, "refused");
		assert.match(result.data.action.reason, /one input source id/);
	}
	const extra = await desktop({ op: "input-source", select: "com.apple.keylayout.US", key: "a" }, signal);
	assert.equal(extra.outcome, "refused");
});

test("listing takes no other arguments", macOS, async () => {
	await assert.rejects(desktop({ op: "input-source", query: "US" }, signal), /no arguments/);
});

test("desktop_input_source offers select alone", () => {
	const tool = desktopTools({ place: "this Mac", app: "Desktop Tools" }).find((tool) => tool.name === "desktop_input_source");
	assert.equal(tool.op, "input-source");
	assert.deepEqual(Object.keys(tool.parameters.properties), ["select"]);
	assert.equal(tool.parameters.additionalProperties, false);
});
