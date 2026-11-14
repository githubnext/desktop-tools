import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

const { version } = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
const launcher = new URL("../dist/mcp.js", import.meta.url).pathname;

/** An app bundle with a client, and a server that prints its arguments and stdin unless `server` is false. */
function app({ name = "Desktop Tools", appVersion = version, server = true } = {}) {
	const directory = realpathSync(mkdtempSync(join(tmpdir(), "desktop-tools-launcher-")));
	const bundle = join(directory, `${name}.app`);
	const macos = join(bundle, "Contents", "MacOS");
	mkdirSync(macos, { recursive: true });
	writeFileSync(join(bundle, "Contents", "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
	<key>CFBundleName</key><string>${name}</string>
	<key>CFBundleShortVersionString</key><string>${appVersion}</string>
</dict></plist>
`);
	const client = join(macos, "desktop-tools-client");
	writeFileSync(client, "#!/bin/sh\nexit 1\n");
	chmodSync(client, 0o755);
	if (server) {
		writeFileSync(join(macos, "desktop-tools-mcp"), `#!/bin/sh\necho "args:$*"\ncat\nexit 7\n`);
		chmodSync(join(macos, "desktop-tools-mcp"), 0o755);
	}
	const state = join(directory, "state");
	mkdirSync(state);
	symlinkSync(client, join(state, "desktop-client"));
	return { bundle, client, state, done: () => rmSync(directory, { recursive: true, force: true }) };
}

const run = (args, state) =>
	spawnSync(process.execPath, [launcher, ...args], {
		input: "hello\n", encoding: "utf8", env: { ...process.env, DESKTOP_TOOLS_STATE: state },
	});

test("it hands stdin, stdout and the exit status over to the app's own server", () => {
	const { state, done } = app();
	try {
		const result = run([], state);
		assert.equal(result.stdout, "args:\nhello\n");
		assert.equal(result.status, 7);
	} finally {
		done();
	}
});

test("--client runs that app's server, passing --socket and --name on; --wire 2 is accepted", () => {
	const { client, done } = app({ name: "Desktop Tools Dev" });
	try {
		const result = run(["--client", client, "--socket", "/tmp/x.sock", "--name", "Dev", "--wire", "2"], "/nonexistent");
		assert.equal(result.stdout, "args:--socket /tmp/x.sock --name Dev\nhello\n");
	} finally {
		done();
	}
});

test("an app without a server of its own fails with its version and what to install", () => {
	const { bundle, state, done } = app({ appVersion: "0.14.0", server: false });
	try {
		const result = run([], state);
		assert.equal(result.status, 1);
		assert.equal(result.stdout, "");
		assert.match(result.stderr, new RegExp(`${bundle.replaceAll(".", "\\.")} is version 0\\.14\\.0, which has no MCP server`));
		assert.match(result.stderr, new RegExp(`install Desktop Tools ${version.replaceAll(".", "\\.")} `));
		assert.match(result.stderr, /Desktop Tools\.app\/Contents\/MacOS\/desktop-tools-mcp", which needs no Node/);
	} finally {
		done();
	}
});

test("an embedder's app without a server says it can't serve MCP", () => {
	const { client, done } = app({ name: "Ace Canary", server: false });
	try {
		const result = run(["--client", client], "/nonexistent");
		assert.equal(result.status, 1);
		assert.match(result.stderr, /Ace Canary bundles no desktop-tools-mcp beside its client, .*, so it can't serve the desktop tools over MCP/);
		assert.match(result.stderr, /Ace Canary must bundle desktop-tools-mcp from the same native build beside that client/);
		assert.match(result.stderr, /https:\/\/github\.com\/githubnext\/desktop-tools\/blob\/main\/docs\/embed\.md/);
		assert.doesNotMatch(result.stderr, /Desktop Tools\.app/);
	} finally {
		done();
	}
});

test("no linked client says to install the app", () => {
	const result = run([], "/nonexistent");
	assert.equal(result.status, 1);
	assert.match(result.stderr, /No Desktop Tools app has linked its client at \/nonexistent\/desktop-client/);
});

test("--wire 1 is refused", () => {
	const result = run(["--wire", "1"], "/nonexistent");
	assert.notEqual(result.status, 0);
	assert.match(result.stderr, /--wire 1 was the Peekaboo stack/);
});
