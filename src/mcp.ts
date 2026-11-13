#!/usr/bin/env node
// desktop-tools-mcp for npx setups and checkouts: it runs the Desktop Tools app's own MCP server, written in Swift, and
// hands stdin and stdout over to it. No MCP traffic passes through Node. Point the MCP config at the app's
// `desktop-tools-mcp` directly to need no Node at all (#237).
import { spawn } from "node:child_process";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { constants as osConstants, homedir } from "node:os";
import { dirname, join } from "node:path";
import { parseArgs } from "node:util";

const { values } = parseArgs({
	options: { client: { type: "string" }, socket: { type: "string" }, name: { type: "string" }, wire: { type: "string" } },
	strict: true,
});
// --wire 2 chose the Swift host's wire while the Peekaboo stack's was the default; it is the only wire now.
if (values.wire !== undefined && values.wire !== "2") {
	throw new Error("--wire 1 was the Peekaboo stack, which is gone; pass --wire 2 or leave it out.");
}
const { version } = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")) as { version: string };

// Desktop Tools.app links its client here. --client names another app's, as <App>.app/Contents/MacOS/desktop-tools-client;
// that app's own server, beside it, is the one that serves it, since a signed host serves only its own app's programs.
const state = process.env.DESKTOP_TOOLS_STATE || join(homedir(), ".local", "state", "desktop-tools");
const client = values.client ?? join(state, "desktop-client");
const linked = (() => {
	try {
		return realpathSync(client);
	} catch {
		return undefined;
	}
})();
const server = linked && join(dirname(linked), "desktop-tools-mcp");

if (!server || !existsSync(server)) {
	const releases = `https://github.com/githubnext/desktop-tools/releases/tag/v${version}`;
	// <App>.app/Contents/MacOS/desktop-tools-client
	const contents = linked && dirname(dirname(linked));
	const plist = (() => {
		try {
			return contents?.endsWith(".app/Contents") ? readFileSync(join(contents, "Info.plist"), "utf8") : undefined;
		} catch {
			return undefined;
		}
	})();
	const appVersion = plist && /<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/.exec(plist)?.[1];
	const appName = plist && /<key>CFBundleName<\/key>\s*<string>([^<]+)<\/string>/.exec(plist)?.[1];
	const found = !linked
		? `No Desktop Tools app has linked its client at ${client}: install and open Desktop Tools ${version} (${releases}).`
		: appName && !appName.startsWith("Desktop Tools")
		// An embedder's app serves MCP only if it bundles desktop-tools-mcp beside its client (docs/embed.md).
		? `${appName} bundles no desktop-tools-mcp beside ${linked}, so it can't serve the desktop tools over MCP. `
			+ "An embedding app can ship desktop-tools-mcp from a native build beside its client (docs/embed.md)."
		: `${dirname(contents!)} is version ${appVersion ?? "unknown"}, which has no MCP server of its own (0.17.0 and later `
			+ `bundle one): install Desktop Tools ${version} (${releases}).`;
	process.stderr.write(
		`desktop-tools-mcp: ${found} Then set the MCP server up as "/Applications/Desktop Tools.app/Contents/MacOS/desktop-tools-mcp", `
			+ "which needs no Node.\n",
	);
	process.exit(1);
}

const args = [...(values.socket ? ["--socket", values.socket] : []), ...(values.name ? ["--name", values.name] : [])];
const child = spawn(server, args, { stdio: "inherit" });
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) process.on(signal, () => child.kill(signal));
child.on("error", (error) => {
	process.stderr.write(`desktop-tools-mcp: Cannot run ${server}: ${error.message}\n`);
	process.exit(1);
});
child.on("exit", (code, signal) => process.exit(code ?? (signal ? 128 + osConstants.signals[signal] : 1)));
