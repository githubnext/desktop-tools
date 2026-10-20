import assert from "node:assert/strict";
import { test } from "node:test";
import { desktopRequest, desktopToolRules, desktopTools } from "../dist/tools.js";

// native2 (wire 2) launches and opens in the background unless asked to activate (#162, #173).
const tools = (wire) => new Map(desktopTools({ place: "this Mac", app: "Desktop Tools", wire }).map((tool) => [tool.name, tool]));

test("wire 2 offers activate on launch and open, and says they stay in the background", () => {
	const [one, two] = [tools(), tools(2)];
	for (const name of ["desktop_launch", "desktop_open"]) {
		assert.equal(one.get(name).parameters.properties.activate, undefined, name);
		assert.match(one.get(name).description, /Foreground:/, name);
		assert.deepEqual(two.get(name).parameters.properties.activate, { type: "boolean" }, name);
		assert.match(two.get(name).description, /Background unless activate is true/, name);
		assert.doesNotMatch(two.get(name).description, /Foreground:/, name);
	}
	const request = desktopRequest(two.get("desktop_launch"), { application: { bundle_id: "com.apple.TextEdit" }, activate: true });
	assert.deepEqual(request, { op: "launch", application: { bundle_id: "com.apple.TextEdit" }, activate: true });
});

test("wire 2 rules add the background-work sentence after the input rule", () => {
	const [one, two] = [desktopToolRules("Desktop Tools"), desktopToolRules("Desktop Tools", 2)];
	assert.equal(two.length, one.length + 1);
	const at = one.findIndex((rule) => rule.startsWith("Input is background"));
	assert.match(two[at + 1], /^Work in the background/);
});
