#!/usr/bin/env node
// Runs the same tool calls through the Swift spike and the Node server and prints where their results differ.
//
//   node native2/scripts/parity.mjs calls <file.json>   each [tool, args], sent as is
//   node native2/scripts/parity.mjs steps <file.json>   each [tool, args] after a fresh inspect of the fixture window
//
// In steps, "$app" and "$window_target" become the fixture's desktop_apps and desktop_windows targets, "$snapshot" the fresh
// snapshot's ID, "$role:AXTextField" the first element with that role, and "$label:Press me" the first element with that
// label. "$app:Name" becomes that app's fresh desktop_apps target,
// "$win:App:Title" the fresh desktop_windows target of its window with that title, and "$movedwin:App:Title" that
// target with its bounds one point off, as a window that moved since. With --ids, PIDs, window and Space IDs are
// ignored too, for steps that launch apps or open windows. Objects are compared with sorted keys; snapshot IDs, process
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
		ids: { type: "boolean", default: false },
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
	.replace(/"observed_at":"[^"]+"/g, '"observed_at":"T"')
	.replace(values.ids ? /"(pid|window_id|space_id|display_current_space_id)":\d+/g : /^\b$/, '"$1":"N"')
	.replace(values.ids ? /"space_ids":\[[\d,]*\]/g : /^\b$/, '"space_ids":"N"');

/** Any other plain observation, such as desktop_screen's, compares without its timings and by its recognized lines' text. */
function plain(observation) {
	const { timings: _t, ...content } = observation;
	if (content.recognized_text?.lines) content.recognized_text = { ...content.recognized_text, lines: content.recognized_text.lines.map((line) => line.text) };
	return content;
}

function summary(result) {
	if (mode === "calls") {
		return { ...result, content: result.content?.map((item) => item.type === "image" ? { type: "image" } : { ...item, text: sorted(parsed(item.text)) }) };
	}
	const data = json(result);
	const { action, ...observation } = typeof data === "object" ? data : {};
	delete observation.diagnostics;
	// A plain observation, such as desktop_inspect's, compares by its content, without Peekaboo's internal metadata.
	if (!action && observation.ui_elements) {
		const { timings: _t, detection_metadata: _d, ...content } = observation;
		if (content.recognized_text?.lines) content.recognized_text = { ...content.recognized_text, lines: content.recognized_text.lines.map((line) => line.text) };
		return { first: result.content?.[0]?.text?.startsWith("{") ? "json" : result.content?.[0]?.text?.split("\n")[0], images: result.content?.filter((item) => item.type === "image").length, fields: Object.keys(observation).sort(), content };
	}
	return {
		first: result.content?.[0]?.text?.startsWith("{") ? "json" : result.content?.[0]?.text?.split("\n")[0],
		images: result.content?.filter((item) => item.type === "image").length,
		fields: Object.keys(observation).sort(),
		action: action ?? (typeof data === "object" ? plain(observation) : data),
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
		target = { pid: app.pid, window: window.window_id, app: app.target, windowTarget: window.target };
	}
	const results = [];
	for (const [tool, args] of entries) {
		let text = JSON.stringify(args ?? {});
		if (mode === "steps") {
			text = text.replaceAll('"$pid"', String(target.pid)).replaceAll('"$window"', String(target.window))
				.replaceAll('"$app"', JSON.stringify(target.app)).replaceAll('"$window_target"', JSON.stringify(target.windowTarget));
			for (const [found, name] of text.matchAll(/"\$app:([^"]*)"/g)) {
				const row = json(await mcp.call("desktop_apps", { query: name })).apps?.find((row) => row.name === name);
				text = text.replace(found, JSON.stringify(row?.target ?? `missing app ${name}`));
			}
			for (const [found, kind, name, title] of text.matchAll(/"\$(win|movedwin):([^:"]*):([^"]*)"/g)) {
				const app = json(await mcp.call("desktop_apps", { query: name })).apps?.find((row) => row.name === name);
				const row = app && json(await mcp.call("desktop_windows", { pid: app.pid })).windows?.find((row) => row.window_title === title);
				const window = row?.target && (kind === "win" ? row.target : { ...row.target, bounds: { ...row.target.bounds, x: row.target.bounds.x + 1 } });
				text = text.replace(found, JSON.stringify(window ?? `missing window ${title}`));
			}
			if (text.includes('"$')) {
				const observed = json(await mcp.call("desktop_inspect", { pid: target.pid, window: target.window }));
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
