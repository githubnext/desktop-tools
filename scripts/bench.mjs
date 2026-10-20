#!/usr/bin/env node
// Times read-only tools through any MCP server, so today's Node server and the Swift spike (#143) run the same scenarios.
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import { performance } from "node:perf_hooks";
import { parseArgs } from "node:util";

const { values } = parseArgs({
	options: {
		server: { type: "string", multiple: true },
		runs: { type: "string", default: "20" },
		only: { type: "string" },
		json: { type: "string" },
		help: { type: "boolean", short: "h" },
	},
	strict: true,
});
if (values.help || !values.server?.length) {
	console.log(`Usage: node scripts/bench.mjs --server "<command>" [--server "<command>"] [--runs 20] [--only apps,windows] [--json <path>]

Each server command is split on spaces and spoken to over stdio. Only read-only tools run.`);
	process.exit(values.help ? 0 : 1);
}
const runs = Number(values.runs);
const only = values.only ? new Set(values.only.split(",")) : undefined;

class Mcp {
	constructor(command) {
		const [file, ...args] = command.split(" ").filter(Boolean);
		this.next = 1;
		this.waiting = new Map();
		this.child = spawn(file, args, { stdio: ["pipe", "pipe", "inherit"] });
		let buffer = "";
		this.child.stdout.on("data", (chunk) => {
			buffer += chunk;
			let newline;
			while ((newline = buffer.indexOf("\n")) >= 0) {
				const line = buffer.slice(0, newline);
				buffer = buffer.slice(newline + 1);
				if (!line.trim()) continue;
				const message = JSON.parse(line);
				const pending = this.waiting.get(message.id);
				if (!pending) continue;
				this.waiting.delete(message.id);
				if (message.error) pending.reject(new Error(message.error.message));
				else pending.resolve(message.result);
			}
		});
		this.child.on("exit", (code) => {
			for (const { reject } of this.waiting.values()) reject(new Error(`MCP server exited (${code}).`));
			this.waiting.clear();
		});
	}

	request(method, params = {}) {
		const id = this.next++;
		return new Promise((resolve, reject) => {
			this.waiting.set(id, { resolve, reject });
			this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
		});
	}

	async call(name, args = {}) {
		const result = await this.request("tools/call", { name, arguments: args });
		const text = (result.content ?? []).filter((c) => c.type === "text").map((c) => c.text);
		const bytes = text.reduce((n, t) => n + Buffer.byteLength(t), 0);
		const json = text.find((t) => t.startsWith("{"));
		if (result.isError) throw new Error(`${name}: ${text.join(" ")}`);
		return { data: json ? JSON.parse(json) : {}, bytes };
	}

	stop() {
		this.child.stdin.end();
		setTimeout(() => this.child.kill(), 2000).unref();
	}
}

const percentile = (sorted, p) => sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))];

async function time(fn) {
	const samples = [];
	let bytes = 0;
	for (let i = 0; i < runs; i++) {
		const start = performance.now();
		const result = await fn();
		samples.push(performance.now() - start);
		bytes = result?.bytes ?? bytes;
	}
	samples.sort((a, b) => a - b);
	const round = (n) => Math.round(n * 10) / 10;
	return { p50: round(percentile(samples, 50)), p95: round(percentile(samples, 95)), min: round(samples[0]), bytes };
}

async function bench(command) {
	const results = {};
	const started = performance.now();
	const mcp = new Mcp(command);
	await mcp.request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "bench" } });
	results.startup = { ms: Math.round(performance.now() - started) };
	const want = (name) => !only || only.has(name);
	try {
		if (want("ping")) results.ping = await time(() => mcp.request("ping"));
		const { data } = await mcp.call("desktop_apps");
		const finder = data.apps?.find((app) => app.bundle_id === "com.apple.finder");
		if (want("apps")) results.apps = await time(() => mcp.call("desktop_apps"));
		if (want("apps_query")) results.apps_query = await time(() => mcp.call("desktop_apps", { query: "finder" }));
		if (want("windows") && finder) results.windows = await time(() => mcp.call("desktop_windows", { pid: finder.pid }));
		if (want("windows_missing")) {
			results.windows_missing = await time(() => mcp.call("desktop_windows", { pid: 999999 }).catch(() => undefined));
		}
	} finally {
		mcp.stop();
	}
	return results;
}

const report = {};
for (const command of values.server) {
	report[command] = await bench(command);
	console.log(`\n${command}`);
	console.table(report[command]);
}
if (values.json) writeFileSync(values.json, `${JSON.stringify({ runs, at: new Date().toISOString(), report }, null, "\t")}\n`);
