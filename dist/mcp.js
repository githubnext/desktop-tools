#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { parseArgs } from "node:util";
import { createDesktop } from "./client.js";
import { isDesktopAction } from "./protocol.js";
import { desktopRequest, desktopToolRules, desktopTools } from "./tools.js";
const { values } = parseArgs({
    options: { client: { type: "string" }, socket: { type: "string" }, name: { type: "string" }, wire: { type: "string" } },
    strict: true,
});
// Desktop Tools.app links its client and serves its socket here; pass all three to use another host app.
const state = process.env.DESKTOP_TOOLS_STATE || join(homedir(), ".local", "state", "desktop-tools");
const { client = join(state, "desktop-client"), socket = join(state, "desktop.sock"), name: host = "Desktop Tools", } = values;
if (values.wire !== undefined && values.wire !== "1" && values.wire !== "2")
    throw new Error("Choose --wire 1 or 2.");
const config = { client, socket, name: host, wire: values.wire === "2" ? 2 : 1 };
const desktop = createDesktop(config);
const { version } = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
// Newest first; an unsupported client version gets the newest, as the MCP lifecycle requires.
const VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
// Guidance mirrors Ace's desktop extension so agents behave alike; tools and their shared rules come from the shared definitions.
const instructions = [
    `Use desktop_* tools to observe and operate native apps on this Mac through ${host}, which holds the macOS permissions.`,
    "Shell commands remain appropriate for builds, files, and preparing clipboard fixtures directly.",
    "",
    "Do not silently substitute AppleScript, osascript, System Events, or self-built Accessibility or CGEvent programs for desktop tools.",
    "Apple Events can raise a separate macOS Automation prompt for each target app, attributed to the calling terminal or agent; Accessibility and Screen Recording grants do not cover them.",
    "Custom input programs bypass the desktop tools' snapshot and exact-target checks, even when they raise no permission prompt.",
    "Before using a fallback, tell the user which native tool or capability cannot do the step and why the fallback is needed, including any Automation prompts it can trigger.",
    "Use the user's existing authorization; this guidance adds no separate approval requirement.",
    "",
    "Action results start with their outcome: completed, refused, or unknown.",
    "For a refusal before dispatch, follow its concrete recovery hint once when applicable, then refresh the observation; a refusal alone does not prove the capability is missing.",
    "After completed, interrupted, or uncertain input, inspect the current target before deciding whether another action is needed. Never replay input just because its follow-up observation failed.",
    "",
    ...desktopToolRules(host),
].join("\n");
const tools = desktopTools({ place: "this Mac", app: host });
const byName = new Map(tools.map((tool) => [tool.name, tool]));
const listed = tools.map(({ name, op, description, parameters }) => ({
    name,
    description,
    inputSchema: parameters,
    annotations: { readOnlyHint: !isDesktopAction({ op }) },
}));
// The host labels the window in use with the agent's name; unknown clients show as "Agent".
const AGENTS = [
    [/claude/i, "Claude"],
    [/codex/i, "Codex"],
    [/cursor/i, "Cursor"],
    [/gemini/i, "Gemini"],
    [/copilot/i, "Copilot"],
];
function agentName(info) {
    const { name, title } = (info ?? {});
    const known = AGENTS.find(([pattern]) => typeof name === "string" && pattern.test(name));
    if (known)
        return known[1];
    return typeof title === "string" && title.trim() ? title.trim().slice(0, 40) : undefined;
}
const send = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);
const fail = (id, code, message) => send({ jsonrpc: "2.0", id, error: { code, message } });
const running = new Map();
// Actions run one at a time, as in Ace; each input depends on the state the previous one left.
let actions = Promise.resolve();
async function call(tool, args, signal) {
    try {
        const result = await desktop(desktopRequest(tool, args), signal);
        const content = [{ type: "text", text: result.text }];
        if (result.outcome)
            content.unshift({ type: "text", text: `Outcome: ${result.outcome}.` });
        if (result.image)
            content.push({ type: "image", ...result.image });
        return { content, isError: result.isError || false };
    }
    catch (error) {
        const text = error instanceof Error ? error.message : String(error);
        return { content: [{ type: "text", text }], isError: true };
    }
}
async function handle(message) {
    const { id, method, params = {} } = message;
    // This server sends no requests, so a message without a method is a stray response.
    if (!method)
        return;
    if (id === undefined) {
        if (method === "notifications/cancelled") {
            running.get(params.requestId)?.abort(new Error(String(params.reason || "Cancelled.")));
        }
        return;
    }
    if (method === "initialize") {
        const requested = String(params.protocolVersion);
        config.agent = agentName(params.clientInfo);
        return send({
            jsonrpc: "2.0",
            id,
            result: {
                protocolVersion: VERSIONS.includes(requested) ? requested : VERSIONS[0],
                capabilities: { tools: {} },
                serverInfo: { name: "desktop-tools", version },
                instructions,
            },
        });
    }
    if (method === "ping")
        return send({ jsonrpc: "2.0", id, result: {} });
    if (method === "tools/list")
        return send({ jsonrpc: "2.0", id, result: { tools: listed } });
    if (method !== "tools/call")
        return fail(id, -32601, `Method not found: ${method}`);
    const tool = byName.get(String(params.name));
    if (!tool)
        return fail(id, -32602, `Unknown tool: ${params.name}`);
    const args = (params.arguments || {});
    const controller = new AbortController();
    running.set(id, controller);
    const { signal } = controller;
    let pending;
    if (isDesktopAction({ op: tool.op })) {
        pending = actions.then(() => call(tool, args, signal));
        actions = pending;
    }
    else {
        pending = call(tool, args, signal);
    }
    const result = await pending;
    running.delete(id);
    // A cancelled request gets no response.
    if (!signal.aborted)
        send({ jsonrpc: "2.0", id, result });
}
createInterface({ input: process.stdin }).on("line", (line) => {
    if (!line.trim())
        return;
    let message;
    try {
        message = JSON.parse(line);
    }
    catch {
        return fail(null, -32700, "Parse error");
    }
    if (!message || typeof message !== "object" || Array.isArray(message)) {
        return fail(null, -32600, "Invalid request");
    }
    void handle(message);
});
