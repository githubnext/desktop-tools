import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { createDesktop } from "../dist/client.js";
import { desktopToolRules } from "../dist/tools.js";

const macOS = { skip: process.platform !== "darwin" && "the client runs only on macOS" };
const signal = new AbortController().signal;
const secret = "dummy-secret-7Q";

/** A native client that records its arguments and request, then replies with `data`. */
function fakeClient(data) {
	const directory = mkdtempSync(join(tmpdir(), "desktop-tools-fill-"));
	const client = join(directory, "client");
	const record = join(directory, "record.json");
	writeFileSync(join(directory, "socket"), "");
	writeFileSync(client, `#!/usr/bin/env node
let input = "";
process.stdin.on("data", (chunk) => input += chunk).on("end", () => {
	require("fs").writeFileSync(${JSON.stringify(record)}, JSON.stringify({ argv: process.argv.slice(2), input }));
	process.stdout.write(JSON.stringify({ success: true, data: ${JSON.stringify(data)} }));
});
`);
	chmodSync(client, 0o755);
	const desktop = createDesktop({ client, socket: join(directory, "socket"), name: "test" });
	return {
		desktop,
		recorded: () => JSON.parse(readFileSync(record, "utf8")),
		done: () => rmSync(directory, { recursive: true, force: true }),
	};
}

test("a fill names one Keychain item or supplies text, and the refusal never quotes the text", macOS, async () => {
	const { desktop, done } = fakeClient({ outcome: "completed", action: "fill", snapshot_id: "S1" });
	try {
		for (const extra of [{}, { service: "a", server: "b" }, { text: secret, account: "me" }, { service: "" }]) {
			const result = await desktop({ op: "fill-password", snapshot: "S1", element: "e1", ...extra }, signal);
			assert.equal(result.outcome, "refused");
			assert.doesNotMatch(result.text, new RegExp(secret));
		}
	} finally {
		done();
	}
});

test("a fill goes to the client's fill operation and returns no secret", macOS, async () => {
	const { desktop, recorded, done } = fakeClient({ outcome: "completed", action: "fill", snapshot_id: "S1" });
	try {
		const result = await desktop({ op: "fill-password", snapshot: "S1", element: "e1", text: secret }, signal);
		assert.equal(result.outcome, "completed");
		assert.doesNotMatch(result.text, new RegExp(secret));
		const { argv, input } = recorded();
		assert.equal(argv.at(-1), "fill");
		assert.deepEqual(JSON.parse(input), { op: "fill-password", snapshot: "S1", element: "e1", text: secret });
	} finally {
		done();
	}
});

test("the shared rules send passwords to the fill tool", () => {
	const rules = desktopToolRules("Desktop Tools").join("\n");
	assert.match(rules, /desktop_fill_password/);
	assert.match(rules, /SECURE_FIELD_REQUIRES_FILL/);
});
