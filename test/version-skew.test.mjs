import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const macOS = { skip: process.platform !== "darwin" && "the client runs only on macOS" };
const { version } = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
const server = new URL("../dist/mcp.js", import.meta.url).pathname;

/** An app from before 0.17.0, with no MCP server of its own, whose client fails as a 0.14 one did (#179). */
function oldApp(appVersion) {
	const directory = realpathSync(mkdtempSync(join(tmpdir(), "desktop-tools-skew-")));
	const app = join(directory, "Desktop Tools.app");
	mkdirSync(join(app, "Contents", "MacOS"), { recursive: true });
	writeFileSync(join(app, "Contents", "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
	<key>CFBundleShortVersionString</key><string>${appVersion}</string>
</dict></plist>
`);
	const client = join(app, "Contents", "MacOS", "desktop-tools-client");
	writeFileSync(client, `#!/usr/bin/env node
process.stdout.write(${JSON.stringify(JSON.stringify({ success: false, error: { code: "HOST_NOT_SERVING", message: "HOST_NOT_SERVING: Desktop Tools isn't serving its socket, so nothing ran." } }))});
process.exit(1);
`);
	chmodSync(client, 0o755);
	const state = join(directory, "state");
	mkdirSync(state);
	symlinkSync(client, join(state, "desktop-client"));
	writeFileSync(join(state, "desktop.sock"), "");
	return { app, state, done: () => rmSync(directory, { recursive: true, force: true }) };
}

function callApps(state) {
	const input = [
		{ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", clientInfo: { name: "test" } } },
		{ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "desktop_apps", arguments: {} } },
	].map((message) => JSON.stringify(message)).join("\n") + "\n";
	const lines = execFileSync(process.execPath, [server], {
		input, encoding: "utf8", env: { ...process.env, DESKTOP_TOOLS_STATE: state },
	}).trim().split("\n").map((line) => JSON.parse(line));
	return lines.find((line) => line.id === 2).result;
}

test("a failed call names the app's version when it differs from the MCP server's", macOS, () => {
	const { app, state, done } = oldApp("0.14.0");
	try {
		const result = callApps(state);
		assert.equal(result.isError, true);
		assert.match(result.content[0].text, /^HOST_NOT_SERVING: /);
		assert.equal(result.content.at(-1).text, `${app} is version 0.14.0, but this MCP server is ${version}. Updating the npx tag `
			+ `doesn't update the app, which holds the macOS permissions: ask the user to install Desktop Tools ${version} from `
			+ `its GitHub release, or to pin the MCP server to v0.14.0.`);
	} finally {
		done();
	}
});

test("a failed call says nothing about versions when the app matches", macOS, () => {
	const { state, done } = oldApp(version);
	try {
		const result = callApps(state);
		assert.equal(result.isError, true);
		assert.equal(result.content.length, 1);
	} finally {
		done();
	}
});
