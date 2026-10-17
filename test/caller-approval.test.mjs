import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { createDesktop, hostRefusal } from "../dist/client.js";
import { desktopToolRules } from "../dist/tools.js";

const macOS = { skip: process.platform !== "darwin" && "the client runs only on macOS" };
const signal = new AbortController().signal;
const waiting = "CALLER_NOT_APPROVED: Desktop Tools hasn't approved perl to control this Mac yet, so nothing ran.";

/** A native client the host refused at its handshake, as it is for a caller the user hasn't allowed. */
function refusedClient() {
	const directory = mkdtempSync(join(tmpdir(), "desktop-tools-caller-"));
	const client = join(directory, "client");
	writeFileSync(join(directory, "socket"), "");
	writeFileSync(client, `#!/usr/bin/env node
process.stdout.write(JSON.stringify({ success: false, error: { code: "permissionDenied", message: ${JSON.stringify(waiting)} } }));
process.exit(1);
`);
	chmodSync(client, 0o755);
	const desktop = createDesktop({ client, socket: join(directory, "socket"), name: "test" });
	return { desktop, done: () => rmSync(directory, { recursive: true, force: true }) };
}

test("host refusals take their own code, and other errors keep theirs", () => {
	assert.deepEqual(hostRefusal({ code: "permissionDenied", message: waiting }), {
		code: "CALLER_NOT_APPROVED",
		message: "Desktop Tools hasn't approved perl to control this Mac yet, so nothing ran.",
	});
	const own = hostRefusal({ code: "permissionDenied", message: "SELF_TARGET_REFUSED: Only the user.", hint: "h" });
	assert.equal(own.code, "SELF_TARGET_REFUSED");
	// Peekaboo's advice to grant a permission would send the agent the wrong way.
	assert.match(own.hint, /^Ask the user to act on Desktop Tools' own/);
	const other = { code: "permissionDenied", message: "Input is paused in Desktop Tools." };
	assert.equal(hostRefusal(other), other);
});

test("an unapproved caller's listing fails with CALLER_NOT_APPROVED", macOS, async () => {
	const { desktop, done } = refusedClient();
	try {
		await assert.rejects(desktop({ op: "apps" }, signal), (error) => {
			assert.match(error.message, /^CALLER_NOT_APPROVED: Desktop Tools hasn't approved perl/);
			assert.doesNotMatch(error.message, /Accessibility and Screen Recording/);
			return true;
		});
	} finally {
		done();
	}
});

test("an unapproved caller's read reports CALLER_NOT_APPROVED as its read error", macOS, async () => {
	const { desktop, done } = refusedClient();
	try {
		const result = await desktop({ op: "read", pid: 1, window: 2 }, signal);
		assert.equal(result.isError, true);
		assert.equal(JSON.parse(result.text).read_error.code, "CALLER_NOT_APPROVED");
	} finally {
		done();
	}
});

test("the shared rules tell agents what both refusals mean", () => {
	const rules = desktopToolRules("Desktop Tools").join("\n");
	assert.match(rules, /CALLER_NOT_APPROVED/);
	assert.match(rules, /SELF_TARGET_REFUSED/);
});
