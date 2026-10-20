#!/usr/bin/env node
// Writes the MCP contract the Swift server (native2, #143) must serve, from today's Node server: its
// instructions and tools/list. With --check, fails when they differ, so the TS definitions stay the source.
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

const dir = new URL("../native2/Sources/DesktopProtocol/contract/", import.meta.url);
const input = [
	{ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "contract" } } },
	{ jsonrpc: "2.0", id: 2, method: "tools/list" },
].map((m) => JSON.stringify(m)).join("\n") + "\n";
const out = execFileSync(process.execPath, [new URL("../dist/mcp.js", import.meta.url).pathname], { input, encoding: "utf8" });
const [init, list] = out.trim().split("\n").map((line) => JSON.parse(line).result);
const files = {
	"instructions.txt": `${init.instructions}\n`,
	"tools.json": `${JSON.stringify(list.tools, null, "\t")}\n`,
};
let stale = false;
for (const [name, text] of Object.entries(files)) {
	const url = new URL(name, dir);
	if (process.argv.includes("--check")) {
		let current = "";
		try { current = readFileSync(url, "utf8"); } catch {}
		if (current !== text) { console.error(`native2/Sources/DesktopProtocol/contract/${name} is stale; run node scripts/contract.mjs`); stale = true; }
	} else writeFileSync(url, text);
}
process.exit(stale ? 1 : 0);
