import assert from "node:assert/strict";
import { test } from "node:test";
import { createDesktop } from "../dist/client.js";
import { desktopTools } from "../dist/tools.js";
import { validateExpect, waitFor } from "../dist/wait.js";

const desktop = createDesktop({ client: "/nonexistent/desktop-client", socket: "/nonexistent/desktop.sock", name: "test" });
const signal = new AbortController().signal;
// The client refuses every request off macOS before validating it.
const macOS = { skip: process.platform !== "darwin" && "the client validates only on macOS" };

test("inspect, read and wait offer web_accessibility as a boolean opt-out", () => {
	const tools = new Map(desktopTools({ place: "this Mac", app: "Desktop Tools" }).map((tool) => [tool.name, tool]));
	for (const name of ["desktop_inspect", "desktop_read", "desktop_wait"]) {
		const property = tools.get(name).parameters.properties.web_accessibility;
		assert.equal(property.type, "boolean", name);
		assert.match(property.description, /false leaves/);
	}
	assert.match(tools.get("desktop_inspect").description, /web_accessibility false/);
});

test("web_accessibility must be true or false", macOS, async () => {
	for (const op of ["inspect", "read"]) {
		await assert.rejects(
			desktop({ op, pid: 1, window: 2, web_accessibility: "no" }, signal),
			/Choose web_accessibility true or false/,
		);
	}
});

test("desktop_wait passes web_accessibility false to its element and text polls only", async () => {
	const inputs = [];
	const reads = {
		async observe() {
			throw new Error("not read");
		},
		async elements(input) {
			inputs.push(input);
			return { text: "ready", truncated: false, truncation: [], window_title: "Page" };
		},
	};
	const wait = { op: "wait", until: "text_contains", pid: 3, window: 4, text: "ready", timeout_ms: 100 };
	await waitFor(reads, { ...wait, web_accessibility: false });
	await waitFor(reads, wait);
	await waitFor(reads, { ...wait, web_accessibility: true });
	assert.deepEqual(inputs, [
		{ pid: 3, window: 4, web_accessibility: false, text: true },
		{ pid: 3, window: 4, text: true },
		{ pid: 3, window: 4, text: true },
	]);
	await assert.rejects(waitFor(reads, { ...wait, web_accessibility: "no" }), /Choose web_accessibility true or false/);
	assert.throws(() => validateExpect({ until: "app_running", pid: 3, web_accessibility: false }), /doesn't use web_accessibility/);
});
