import assert from "node:assert/strict";
import { test } from "node:test";
import { createDesktop } from "../dist/client.js";
import { desktopTools } from "../dist/tools.js";

// Every request here is refused before the native client would run.
const desktop = createDesktop({ client: "/nonexistent/desktop-client", socket: "/nonexistent/desktop.sock", name: "test" });
const signal = new AbortController().signal;
// The client refuses every request off macOS before validating it.
const macOS = { skip: process.platform !== "darwin" && "the client validates only on macOS" };

async function refusal(request) {
	const result = await desktop({ op: "system-key", ...request }, signal);
	assert.equal(result.outcome, "refused", JSON.stringify(request));
	return JSON.parse(result.text).action.reason;
}

test("media, volume and brightness keys take no modifiers", macOS, async () => {
	assert.match(await refusal({ key: "volume_up", modifiers: ["shift"] }), /no modifiers/);
	assert.match(await refusal({ key: "mute", modifiers: [] }), /no modifiers/);
	assert.match(await refusal({ key: "volume_loud" }), /named key/);
});

test("desktop_system_key lists the media keys", () => {
	const tool = desktopTools({ place: "this Mac", app: "Desktop Tools" }).find((tool) => tool.name === "desktop_system_key");
	const keys = tool.parameters.properties.key.anyOf.map((option) => option.const).filter(Boolean);
	for (const key of ["play_pause", "next_track", "volume_down", "brightness_up", "keyboard_brightness_down", "escape"]) {
		assert.ok(keys.includes(key), key);
	}
});
