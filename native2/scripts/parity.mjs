#!/usr/bin/env node
// Runs the same tool calls through the Swift spike and the Node server and prints where their results differ.
//
//   node native2/scripts/parity.mjs calls <file.json>   each [tool, args], sent as is
//   node native2/scripts/parity.mjs steps <file.json>   each [tool, args] after a fresh inspect of the fixture window
//
// In steps, "$snapshot" becomes the fresh snapshot's ID, "$role:AXTextField" the first element with that role, and
// "$label:Press me" the first element with that label. Objects are compared with sorted keys; snapshot IDs, process
// start identities, the route (local in Swift, bridge in Node), timings and the observation's own fields are ignored, so an
// action compares by its action object and the observation's field names.
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { parseArgs } from "node:util";

const { values, positionals } = parseArgs({
	allowPositionals: true,
	options: {
		swift: { type: "string", default: "native2/.build/release/desktop-tools-mcp" },
		node: { type: "string", default: "node dist/mcp.js" },
		app: { type: "string", default: "fixture" },
		window: { type: "string", default: "Click Fixture" },
		all: { type: "boolean", default: false },
	},
});
const [mode, file] = positionals;
if (!["calls", "steps"].includes(mode) || !file) {
	console.error("Usage: node native2/scripts/parity.mjs calls|steps <file.json> [--swift cmd] [--node cmd] [--app name] [--window title] [--all]");
	process.exit(1);
}
const entries = JSON.parse(readFileSync(file, "utf8"));

function server(command) {
	const [executable, ...args] = command.split(" ").filter(Boolean);
	const child = spawn(executable, args, { stdio: ["pipe", "pipe", "inherit"] });
	const waiting = new Map();
	let buffer = "", next = 1;
	child.stdout.on("data", (chunk) => {
		buffer += chunk;
		let newline;
		while ((newline = buffer.indexOf("\n")) >= 0) {
			const line = buffer.slice(0, newline);
			buffer = buffer.slice(newline + 1);
			if (!line.trim()) continue;
			const message = JSON.parse(line);
			waiting.get(message.id)?.(message.result ?? message.error);
		}
	});
	const request = (method, params = {}) => new Promise((resolve) => {
		const id = next++;
		waiting.set(id, resolve);
		child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
	});
	return { request, call: (name, args) => request("tools/call", { name, arguments: args }), stop: () => child.kill() };
}

const sorted = (value) => Array.isArray(value) ? value.map(sorted)
	: value && typeof value === "object" ? Object.fromEntries(Object.keys(value).sort().map((key) => [key, sorted(value[key])]))
	: value;
const parsed = (text) => { try { return JSON.parse(text); } catch { return text; } };
const json = (result) => parsed(result.content?.find((item) => item.text?.startsWith("{"))?.text ?? "{}");
const normal = (value) => JSON.stringify(sorted(value))
	.replace(/(snap|ps1)_[\w-]+/g, "S")
	.replace(/"change_count":\d+/g, '"change_count":"C"')
	.replace(/"process_start_identity_decimal":"\d+"/g, '"process_start_identity_decimal":"P"')
	.replace(/"route":"(local|bridge)"/g, '"route":"R"')
	.replace(/"(elapsed_ms|polls)":\d+/g, '"$1":"T"')
	.replace(/"observed_at":"[^"]+"/g, '"observed_at":"T"');

function summary(result) {
	if (mode === "calls") {
		return { ...result, content: result.content?.map((item) => item.type === "image" ? { type: "image" } : { ...item, text: sorted(parsed(item.text)) }) };
	}
	const data = json(result);
	const { action, ...observation } = typeof data === "object" ? data : {};
	delete observation.diagnostics;
	return {
		first: result.content?.[0]?.text?.startsWith("{") ? "json" : result.content?.[0]?.text?.split("\n")[0],
		images: result.content?.filter((item) => item.type === "image").length,
		fields: Object.keys(observation).sort(),
		action: action ?? data,
	};
}

async function run(command) {
	const mcp = server(command);
	await mcp.request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "parity" } });
	let target;
	if (mode === "steps") {
		const app = json(await mcp.call("desktop_apps", { query: values.app })).apps?.find((row) => row.name === values.app);
		if (!app) throw new Error(`${values.app} isn't running.`);
		const window = json(await mcp.call("desktop_windows", { pid: app.pid })).windows?.find((row) => row.window_title === values.window);
		if (!window) throw new Error(`${values.app} has no window titled ${values.window}.`);
		target = { pid: app.pid, window: window.window_id };
	}
	const results = [];
	for (const [tool, args] of entries) {
		let text = JSON.stringify(args ?? {});
		if (mode === "steps") {
			text = text.replaceAll('"$pid"', String(target.pid)).replaceAll('"$window"', String(target.window));
			if (text.includes('"$')) {
				const observed = json(await mcp.call("desktop_inspect", target));
				text = text.replaceAll('"$snapshot"', JSON.stringify(observed.snapshot_id)).replace(/"\$(role|label):([^"]*)"/g, (_, kind, wanted) => {
					const found = observed.ui_elements?.find((element) => kind === "role" ? element.attributes?.role === wanted : element.label === wanted);
					return JSON.stringify(found?.id ?? `missing ${kind} ${wanted}`);
				});
			}
		}
		const started = performance.now();
		const result = await mcp.call(tool, JSON.parse(text));
		results.push({ summary: summary(result), ms: Math.round(performance.now() - started) });
	}
	mcp.stop();
	return results;
}

// One server at a time: they drive the same desktop.
const swift = await run(values.swift);
const node = await run(values.node);
let same = 0;
entries.forEach(([tool, args], index) => {
	const [a, b] = [normal(swift[index].summary), normal(node[index].summary)];
	const label = `${tool} ${JSON.stringify(args ?? {})}`.slice(0, 120);
	if (a === b) {
		same++;
		if (values.all) console.log(`SAME ${label}  (swift ${swift[index].ms} ms, node ${node[index].ms} ms)`);
		return;
	}
	console.log(`DIFF ${label}  (swift ${swift[index].ms} ms, node ${node[index].ms} ms)`);
	console.log(`  swift: ${a.slice(0, 1500)}`);
	console.log(`  node:  ${b.slice(0, 1500)}`);
});
console.log(`${same} of ${entries.length} the same`);
