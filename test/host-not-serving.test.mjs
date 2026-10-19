import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { createDesktop } from "../dist/client.js";

const macOS = { skip: process.platform !== "darwin" && "the client runs only on macOS" };
const signal = new AbortController().signal;

/** A native client whose connect was refused, as it is when a stale socket file has no host listening. */
function refusedClient() {
	const directory = mkdtempSync(join(tmpdir(), "desktop-tools-serving-"));
	const client = join(directory, "client");
	writeFileSync(join(directory, "socket"), "");
	writeFileSync(client, `#!/usr/bin/env node
process.stdout.write(JSON.stringify({ success: false, error: { code: "DESKTOP_ERROR", message: "The operation couldn’t be completed. Connection refused." } }));
process.exit(1);
`);
	chmodSync(client, 0o755);
	const socket = join(directory, "socket");
	const desktop = createDesktop({ client, socket, name: "Desktop Tools" });
	return { desktop, socket, done: () => rmSync(directory, { recursive: true, force: true }) };
}

test("a refused connection says the host isn't serving its socket", macOS, async () => {
	const { desktop, socket, done } = refusedClient();
	try {
		await assert.rejects(desktop({ op: "apps" }, signal), (error) => {
			assert.equal(error.message, `HOST_NOT_SERVING: Desktop Tools isn't serving ${socket}, so nothing ran. Ask the user to check the status line in its menu, or to quit and reopen it.`);
			return true;
		});
	} finally {
		done();
	}
});
