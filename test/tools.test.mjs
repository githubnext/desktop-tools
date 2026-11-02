import assert from "node:assert/strict";
import { test } from "node:test";
import { desktopRequest, desktopToolRules, desktopTools, EXPECT_MAX_MS } from "../dist/tools.js";

const tools = new Map(desktopTools({ place: "this Mac", app: "Desktop Tools" }).map((tool) => [tool.name, tool]));
const rules = desktopToolRules("Desktop Tools");

// Launching and opening stay in the background unless asked to activate (#162, #173).
test("launch and open offer activate, and say they stay in the background", () => {
	for (const name of ["desktop_launch", "desktop_open"]) {
		assert.deepEqual(tools.get(name).parameters.properties.activate, { type: "boolean" }, name);
		assert.match(tools.get(name).description, /Background unless activate is true/, name);
		assert.doesNotMatch(tools.get(name).description, /Foreground:/, name);
	}
	const request = desktopRequest(tools.get("desktop_launch"), { application: { bundle_id: "com.apple.TextEdit" }, activate: true });
	assert.deepEqual(request, { op: "launch", application: { bundle_id: "com.apple.TextEdit" }, activate: true });
});

test("the rules add the background-work sentence after the input rule", () => {
	const at = rules.findIndex((rule) => rule.startsWith("Input is background"));
	assert.match(rules[at + 1], /^Work in the background/);
});

test("the shared rules tell agents what both host refusals mean, and send passwords to the fill tool", () => {
	const text = rules.join("\n");
	for (const pattern of [/CALLER_NOT_APPROVED/, /SELF_TARGET_REFUSED/, /desktop_fill_password/, /SECURE_FIELD_REQUIRES_FILL/]) {
		assert.match(text, pattern);
	}
});

test("click, key, system_key, drag and insert take expect; other actions don't", () => {
	const taking = [...tools.values()].filter((tool) => tool.parameters.properties?.expect).map((tool) => tool.name).sort();
	assert.deepEqual(taking, ["desktop_click", "desktop_drag", "desktop_insert", "desktop_key", "desktop_system_key"]);
	const expect = tools.get("desktop_click").parameters.properties.expect;
	assert.equal(expect.properties.timeout_ms.maximum, EXPECT_MAX_MS);
	assert.ok(expect.properties.until.enum.length > 10);
});

test("desktop_input_source offers select alone", () => {
	const tool = tools.get("desktop_input_source");
	assert.equal(tool.op, "input-source");
	assert.deepEqual(Object.keys(tool.parameters.properties), ["select"]);
	assert.equal(tool.parameters.additionalProperties, false);
});

test("desktop_system_key lists the media keys", () => {
	const keys = tools.get("desktop_system_key").parameters.properties.key.anyOf[0].enum;
	for (const key of ["play_pause", "next_track", "volume_down", "brightness_up", "keyboard_brightness_down", "escape"]) {
		assert.ok(keys.includes(key), key);
	}
});

test("inspect, read and wait offer web_accessibility as a boolean opt-out", () => {
	for (const name of ["desktop_inspect", "desktop_read", "desktop_wait"]) {
		const property = tools.get(name).parameters.properties.web_accessibility;
		assert.equal(property.type, "boolean", name);
		assert.match(property.description, /false leaves/);
	}
	assert.match(tools.get("desktop_inspect").description, /web_accessibility false/);
});

test("desktop_insert exposes the attachment form, the clipboard choice and foreground typing", () => {
	const insert = tools.get("desktop_insert");
	assert.deepEqual(insert.parameters.required, ["snapshot"]);
	const { format, paths, clipboard, foreground } = insert.parameters.properties;
	assert.deepEqual(format.enum, ["image", "files"]);
	assert.equal(paths.maxItems, 32);
	assert.deepEqual(clipboard.enum, ["restore", "replace"]);
	assert.deepEqual(foreground, { type: "boolean" });
	assert.match(insert.description, /PASTE_UNVERIFIABLE_RECEIVER/);
	assert.match(insert.description, /left_replaced/);
	assert.match(insert.description, /Finder window.*PASTE_NAME_EXISTS/);
});
