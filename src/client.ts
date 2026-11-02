import { type ChildProcess, spawn } from "node:child_process";
import { existsSync } from "node:fs";

import type { DesktopOutcome, DesktopRequest, DesktopResult } from "./protocol.js";

/** Explicit paths for one signed host and client pair; nothing is discovered. */
export type DesktopConfig = {
	/** Absolute path of the signed `desktop-tools-client`, the one bundled in the host app. */
	client: string;
	/** Unix socket passed to `desktop_tools_start` in the host app. */
	socket: string;
	/** Host app name used in permission guidance. */
	name?: string;
	/** Agent named in the host's window label, such as "Claude"; read at each call, so it can be set later. */
	agent?: string;
	/**
	 * Return results whole, with detection metadata, timings, receipts and every window, instead of the compact shape
	 * written for models. Defaults to `DESKTOP_TOOLS_VERBOSE=1` in the environment.
	 */
	verbose?: boolean;
	/**
	 * Ignored. The Swift host's wire, which this option once chose, is the only one since the Peekaboo stack was
	 * removed; it stays so configs that pass `wire: 2` still type-check.
	 */
	wire?: 2;
};
/** `data` is the parsed final `text`; image bytes stay only in `image`. */
export type DesktopClientResult = DesktopResult & { data: unknown };
export type DesktopClient = (
	request: DesktopRequest,
	signal?: AbortSignal,
) => Promise<DesktopClientResult>;

class NativeError extends Error {
	constructor(readonly code: string, message: string) {
		super(message);
	}
}

/**
 * Creates a client bound to one host socket and signed client. Each request goes whole to the client as one tool call,
 * `desktop_` and its op, and the tool result comes back as the MCP server would send it: the host checks the arguments
 * and compacts the result.
 */
export function createDesktop(config: DesktopConfig): DesktopClient {
	return forwarder(config);
}

type ToolCallResult = { content?: ({ type: "text"; text: string } | { type: "image"; data: string; mimeType: string })[]; isError?: boolean };

type ServedReply = { id?: number | null; result?: ToolCallResult; error?: { code: string; message: string } };

/**
 * The client in `--serve` mode: one process and one host connection for every call, so a call costs no spawn,
 * handshake or connect. Calls overlap, each under its own id; a process that exits is replaced on the next call. Its
 * environment names the agent, so there is one per config. It holds the event loop only while a call waits.
 */
function served(config: DesktopConfig) {
	let child: ChildProcess | undefined;
	let next = 1;
	const waiting = new Map<number, { resolve: (reply: ServedReply) => void; reject: (error: Error) => void }>();

	const hold = (held: boolean) => {
		for (const handle of [child, child?.stdin, child?.stdout] as ({ ref(): void; unref(): void } | undefined)[]) {
			if (held) handle?.ref();
			else handle?.unref();
		}
	};
	const settle = (id: number) => {
		const call = waiting.get(id);
		waiting.delete(id);
		if (waiting.size === 0) hold(false);
		return call;
	};

	const start = () => {
		const spawned = spawn(config.client, [config.socket, "--serve"], {
			// The host reads this from the client while a request is pending, to label the window in use.
			env: config.agent ? { ...process.env, DESKTOP_TOOLS_AGENT: config.agent } : process.env,
			stdio: ["pipe", "pipe", "ignore"],
		});
		child = spawned;
		let buffered = "";
		spawned.stdout!.setEncoding("utf8");
		spawned.stdout!.on("data", (chunk: string) => {
			buffered += chunk;
			let end: number;
			while ((end = buffered.indexOf("\n")) >= 0) {
				const line = buffered.slice(0, end);
				buffered = buffered.slice(end + 1);
				if (!line.trim()) continue;
				let reply: ServedReply;
				try {
					reply = JSON.parse(line) as ServedReply;
				} catch {
					continue;
				}
				// An untagged error means it never connected, so none of the waiting calls ran.
				if (typeof reply.id !== "number") {
					if (reply.error) for (const id of [...waiting.keys()]) settle(id)!.resolve(reply);
					continue;
				}
				settle(reply.id)?.resolve(reply);
			}
		});
		// A write after the client exited fails here; the exit below ends the waiting calls.
		spawned.stdin!.on("error", () => {});
		const exited = (reason: string) => {
			if (child === spawned) child = undefined;
			for (const id of [...waiting.keys()]) settle(id)!.reject(new Error(`The native desktop client ${reason}.`));
		};
		spawned.on("error", (error) => exited(`failed: ${error.message}`));
		// close, not exit, so the replies it wrote before exiting are read first.
		spawned.on("close", (code, signal) => exited(signal ? `was killed by ${signal}` : `exited with status ${code}`));
		return spawned;
	};

	return (tool: string, args: Record<string, unknown>, verbose: boolean, signal: AbortSignal) =>
		new Promise<ServedReply>((resolve, reject) => {
			signal.throwIfAborted();
			const spawned = child ?? start();
			const id = next++;
			const abort = () => {
				if (!settle(id)) return;
				spawned.stdin!.write(`${JSON.stringify({ cancel: id })}\n`);
				reject(signal.reason as Error);
			};
			waiting.set(id, {
				resolve: (reply) => { signal.removeEventListener("abort", abort); resolve(reply); },
				reject: (error) => { signal.removeEventListener("abort", abort); reject(error); },
			});
			hold(true);
			signal.addEventListener("abort", abort, { once: true });
			spawned.stdin!.write(`${JSON.stringify({ id, tool, arguments: args, ...(verbose ? { verbose: true } : {}) })}\n`);
		});
}

function forwarder(config: DesktopConfig): DesktopClient {
	const call = served(config);
	return async (request, signal = new AbortController().signal) => {
		const { client, socket } = config;
		if (!existsSync(client)) throw new Error(`The native desktop client is missing at ${client}.`);
		const { op, ...args } = request;
		const verbose = config.verbose ?? process.env.DESKTOP_TOOLS_VERBOSE === "1";
		const reply = await call(`desktop_${op.replaceAll("-", "_")}`, args, verbose, signal);
		if (reply.error) {
			const name = config.name ?? "the desktop host app";
			if (reply.error.code === "HOST_NOT_RUNNING") {
				throw new NativeError(
					"HOST_NOT_RUNNING",
					`HOST_NOT_RUNNING: ${name} isn't serving ${socket}, so nothing ran. Ask the user to open ${name}.`,
				);
			}
			if (reply.error.code === "HOST_NOT_SERVING") {
				throw new NativeError(
					"HOST_NOT_SERVING",
					`HOST_NOT_SERVING: ${name} isn't serving ${socket}, so nothing ran. Ask the user to check the status line in its menu, or to quit and reopen it.`,
				);
			}
			throw new NativeError(reply.error.code, reply.error.message);
		}
		const content = reply.result?.content ?? [];
		const texts = content.flatMap((item) => item.type === "text" ? [item.text] : []);
		const outcome = texts.length > 1 ? /^Outcome: (completed|refused|unknown)\.$/.exec(texts[0]!)?.[1] : undefined;
		const text = texts[outcome ? 1 : 0] ?? "";
		let data: unknown;
		try {
			data = JSON.parse(text);
		} catch {
			// Plain text is an error the MCP server reports as is, as it does for a thrown one.
			throw new Error(text || "The native desktop client returned no result.");
		}
		const image = content.find((item) => item.type === "image");
		return {
			text,
			data,
			...(outcome ? { outcome: outcome as DesktopOutcome } : {}),
			...(image?.type === "image" ? { image: { data: image.data, mimeType: image.mimeType } } : {}),
			...(reply.result?.isError ? { isError: true } : {}),
		};
	};
}
