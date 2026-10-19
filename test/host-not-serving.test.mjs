import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { createDesktop } from "../dist/client.js";

const macOS = { skip: process.platform !== "darwin" && "the client runs only on macOS" };
const signal = new AbortController().signal;

/** A native client that fails with `error`, beside a socket path that exists only when `socket` is set. */
function failingClient(error, { socket: present = true } = {}) {
	const directory = mkdtempSync(join(tmpdir(), "desktop-tools-serving-"));
	const client = join(directory, "client");
	const socket = join(directory, "socket");
	if (present) writeFileSync(socket, "");
	writeFileSync(client, `#!/usr/bin/env node
process.stdout.write(${JSON.stringify(JSON.stringify({ success: false, error }))});
process.exit(1);
`);
	chmodSync(client, 0o755);
	const desktop = createDesktop({ client, socket, name: "Desktop Tools" });
	return { desktop, socket, done: () => rmSync(directory, { recursive: true, force: true }) };
}

const refused = { code: "DESKTOP_ERROR", message: "The operation couldn’t be completed. Connection refused." };

test("an older client's refused connection says the host isn't serving its socket", macOS, async () => {
	const { desktop, socket, done } = failingClient(refused);
	try {
		await assert.rejects(desktop({ op: "apps" }, signal), (error) => {
			assert.equal(error.message, `HOST_NOT_SERVING: Desktop Tools isn't serving ${socket}, so nothing ran. Ask the user to check the status line in its menu, or to quit and reopen it.`);
			return true;
		});
	} finally {
		done();
	}
});

test("a missing socket still runs the client, so it can open the host app", macOS, async () => {
	const missing = { code: "DESKTOP_ERROR", message: "The operation couldn’t be completed. No such file or directory." };
	const { desktop, socket, done } = failingClient(missing, { socket: false });
	try {
		await assert.rejects(desktop({ op: "apps" }, signal), (error) => {
			assert.equal(error.message, `HOST_NOT_RUNNING: Desktop Tools isn't serving ${socket}, so nothing ran. Ask the user to open Desktop Tools.`);
			return true;
		});
	} finally {
		done();
	}
});

test("the client's own host errors pass through unchanged", macOS, async () => {
	for (const code of ["HOST_NOT_RUNNING", "HOST_NOT_SERVING"]) {
		const message = `${code}: Desktop Tools (pid 1) is running but isn't serving /tmp/x.sock, and opening it again didn't fix that within 10 s, so nothing ran.`;
		const { desktop, done } = failingClient({ code, message }, { socket: false });
		try {
			await assert.rejects(desktop({ op: "apps" }, signal), (error) => {
				assert.equal(error.message, message);
				return true;
			});
		} finally {
			done();
		}
	}
});
