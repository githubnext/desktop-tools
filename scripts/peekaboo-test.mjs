#!/usr/bin/env node
// Runs Peekaboo's Swift tests from a native build's checkout, safely for a Mac other sessions are using.
//
//   npm run peekaboo-test -- --scratch /tmp/x --filter 'PeekabooBridgeRequestPlanTests' [--filter ...]
//       [--package core|automationkit] [--build] [--timeout 540]
//
// Peekaboo's tests take the real per-user ~/.peekaboo locks, so a stuck run blocks every desktop
// operation on the Mac. This runs swift test in the foreground in its own process group, with a hard
// time limit, and afterwards kills any swiftpm-testing-helper or test bundle left from this run's
// test scratch, never another run's. It removes AI provider credentials from the environment, which
// PeekabooCore's agent tests refuse to run with (credentialEnvironmentPresent).
import { execFileSync, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const PACKAGES = { core: "Core/PeekabooCore", automationkit: "Core/PeekabooAutomationKit" };
const MAX_TIMEOUT = 580;

/** The environment without AI provider credentials: Tachikoma's *_API_KEY and *_TOKEN variables, and Peekaboo's provider list. */
export function testEnvironment(env) {
	return Object.fromEntries(
		Object.entries(env).filter(([name]) => !/(_API_KEY|_TOKEN)$/.test(name) && name !== "PEEKABOO_AI_PROVIDERS"),
	);
}

export function parseArgs(argv) {
	const options = { filters: [], package: "core", build: false, timeout: 540 };
	for (let index = 0; index < argv.length; index++) {
		const flag = argv[index];
		const value = () => {
			const next = argv[++index];
			if (next === undefined) throw new Error(`${flag} needs a value.`);
			return next;
		};
		if (flag === "--scratch") options.scratch = resolve(value());
		else if (flag === "--test-scratch") options.testScratch = resolve(value());
		else if (flag === "--filter") options.filters.push(value());
		else if (flag === "--package") options.package = value();
		else if (flag === "--timeout") options.timeout = Number(value());
		else if (flag === "--build") options.build = true;
		else throw new Error(`Unknown argument ${flag}.`);
	}
	if (!options.scratch) throw new Error("Pass --scratch, the scratch path of a node dist/build.js run.");
	if (!options.filters.length) throw new Error("Pass at least one narrow --filter; a whole-package run holds the locks too long.");
	if (options.filters.some((filter) => !filter.trim() || /^\.?\*?$/.test(filter))) throw new Error("A --filter must name tests.");
	if (!PACKAGES[options.package]) throw new Error(`--package is ${Object.keys(PACKAGES).join(" or ")}.`);
	if (!Number.isInteger(options.timeout) || options.timeout < 10 || options.timeout > MAX_TIMEOUT) {
		throw new Error(`--timeout is whole seconds from 10 to ${MAX_TIMEOUT}, to stay under a 600 s tool call.`);
	}
	options.testScratch ??= `${options.scratch}-tests-${options.package}`;
	return options;
}

/** Test processes of this test scratch: a testing helper given its bundle, and the bundle's own executable. */
function leftovers(testScratch) {
	const output = execFileSync("ps", ["-axww", "-o", "pid=,command="], { encoding: "utf8" });
	return output.split("\n").flatMap((line) => {
		const match = /^\s*(\d+)\s+(.*)$/.exec(line);
		if (!match || Number(match[1]) === process.pid) return [];
		const command = match[2];
		// Judge by the executable, not the whole line, which a shell running this script also matches.
		const executable = command.split(" ")[0];
		const helper = executable.endsWith("/swiftpm-testing-helper") && command.includes(testScratch);
		const bundle = executable.startsWith(`${testScratch}/`) && executable.includes(".xctest/");
		return helper || bundle ? [{ pid: Number(match[1]), command }] : [];
	});
}

/** Runs one command in its own process group, killing the group on timeout and on exit. */
function runGroup(command, args, { cwd, env, deadline }) {
	return new Promise((resolvePromise) => {
		const child = spawn(command, args, { cwd, env, stdio: "inherit", detached: true });
		const killGroup = (signal) => {
			try {
				process.kill(-child.pid, signal);
			} catch {}
		};
		let timedOut = false;
		const timer = setTimeout(() => {
			timedOut = true;
			console.error(`peekaboo-test: timed out; stopping ${command}`);
			killGroup("SIGTERM");
			setTimeout(() => killGroup("SIGKILL"), 2000).unref();
		}, Math.max(0, deadline - Date.now()));
		const interrupt = () => {
			killGroup("SIGKILL");
		};
		process.on("SIGINT", interrupt).on("SIGTERM", interrupt);
		child.on("exit", (code, signal) => {
			clearTimeout(timer);
			process.off("SIGINT", interrupt).off("SIGTERM", interrupt);
			// Anything left in the group, such as an orphaned test helper.
			killGroup("SIGKILL");
			resolvePromise(timedOut ? 124 : code ?? (signal ? 1 : 0));
		});
	});
}

async function main() {
	const options = parseArgs(process.argv.slice(2));
	const packagePath = join(options.scratch, "checkouts/Peekaboo", PACKAGES[options.package]);
	if (!existsSync(packagePath)) throw new Error(`No Peekaboo checkout at ${packagePath}; run node dist/build.js --scratch ${options.scratch} first.`);
	const running = leftovers(options.testScratch);
	if (running.length) {
		throw new Error(`Another run is using ${options.testScratch} (pid ${running.map((item) => item.pid).join(", ")}); wait for it or pass another --test-scratch.`);
	}
	const env = testEnvironment(process.env);
	const removed = Object.keys(process.env).filter((name) => !(name in env));
	if (removed.length) console.error(`peekaboo-test: running without ${removed.join(", ")}`);
	const deadline = Date.now() + options.timeout * 1000;
	const swift = ["--package-path", packagePath, "--scratch-path", options.testScratch];
	let status = 0;
	try {
		if (options.build) status = await runGroup("xcrun", ["swift", "build", "--build-tests", ...swift], { env, deadline });
		if (status === 0) {
			const filters = options.filters.flatMap((filter) => ["--filter", filter]);
			status = await runGroup("xcrun", ["swift", "test", "--skip-build", ...swift, ...filters], { env, deadline });
		}
	} finally {
		// A helper can leave the group; kill only those under this run's test scratch, then check again.
		for (const { pid, command } of leftovers(options.testScratch)) {
			console.error(`peekaboo-test: killing leftover ${pid} ${command.slice(0, 120)}`);
			try {
				process.kill(pid, "SIGKILL");
			} catch {}
		}
		const remaining = leftovers(options.testScratch);
		if (remaining.length) {
			console.error(`peekaboo-test: still running after kill: ${remaining.map((item) => item.pid).join(", ")}`);
			status ||= 1;
		}
	}
	process.exitCode = status;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
	main().catch((error) => {
		console.error(`peekaboo-test: ${error.message}`);
		process.exitCode = 2;
	});
}
