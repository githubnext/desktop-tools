import assert from "node:assert/strict";
import { test } from "node:test";
import { createDesktop } from "../dist/client.js";
import { desktopTools } from "../dist/tools.js";

const desktop = createDesktop({ client: "/nonexistent/desktop-client", socket: "/nonexistent/desktop.sock", name: "test" });
const signal = new AbortController().signal;
// The client refuses every request off macOS before validating it.
const macOS = { skip: process.platform !== "darwin" && "the client validates only on macOS" };

test("inspect and read offer web_accessibility as a boolean opt-out", () => {
	const tools = new Map(desktopTools({ place: "this Mac", app: "Desktop Tools" }).map((tool) => [tool.name, tool]));
	for (const name of ["desktop_inspect", "desktop_read"]) {
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
