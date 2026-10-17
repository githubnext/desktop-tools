import assert from "node:assert/strict";
import { test } from "node:test";
import { parseArgs, testEnvironment } from "../scripts/peekaboo-test.mjs";

test("the Peekaboo test run drops AI provider credentials and keeps the rest", () => {
	const env = testEnvironment({
		PATH: "/usr/bin",
		HOME: "/Users/me",
		OPENAI_API_KEY: "x",
		ANTHROPIC_API_KEY: "x",
		AZURE_OPENAI_BEARER_TOKEN: "x",
		CLAUDE_CODE_OAUTH_TOKEN: "x",
		PEEKABOO_AI_PROVIDERS: "x",
	});
	assert.deepEqual(env, { PATH: "/usr/bin", HOME: "/Users/me" });
});

test("a Peekaboo test run needs a scratch, a narrow filter and a timeout under the tool limit", () => {
	assert.throws(() => parseArgs(["--filter", "Plan"]), /--scratch/);
	assert.throws(() => parseArgs(["--scratch", "/tmp/s"]), /narrow --filter/);
	assert.throws(() => parseArgs(["--scratch", "/tmp/s", "--filter", ".*"]), /must name tests/);
	assert.throws(() => parseArgs(["--scratch", "/tmp/s", "--filter", "Plan", "--timeout", "900"]), /10 to 580/);
	assert.throws(() => parseArgs(["--scratch", "/tmp/s", "--filter", "Plan", "--package", "cli"]), /core or automationkit/);
	const options = parseArgs(["--scratch", "/tmp/s", "--filter", "A", "--filter", "B", "--build"]);
	assert.deepEqual(options, {
		filters: ["A", "B"],
		package: "core",
		build: true,
		timeout: 540,
		scratch: "/tmp/s",
		testScratch: "/tmp/s-tests-core",
	});
});
