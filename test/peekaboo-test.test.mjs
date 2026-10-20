import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { parseArgs, testEnvironment } from "../scripts/peekaboo-test.mjs";

const root = dirname(dirname(fileURLToPath(import.meta.url)));

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

test("a Peekaboo test run needs a narrow filter and a timeout under the tool limit", () => {
	assert.throws(() => parseArgs([]), /narrow --filter/);
	assert.throws(() => parseArgs(["--filter", ".*"]), /must name tests/);
	assert.throws(() => parseArgs(["--filter", "Plan", "--timeout", "900"]), /10 to 580/);
	assert.throws(() => parseArgs(["--filter", "Plan", "--package", "cli"]), /core or automationkit/);
	assert.throws(() => parseArgs(["--scratch", "/tmp/s", "--filter", "Plan"]), /Unknown argument --scratch/);
	const options = parseArgs(["--filter", "A", "--filter", "B", "--build"]);
	assert.deepEqual(options, {
		filters: ["A", "B"],
		package: "core",
		build: true,
		timeout: 540,
		testScratch: join(root, ".build", "peekaboo-tests-core"),
	});
	assert.equal(parseArgs(["--filter", "A", "--test-scratch", "/tmp/t"]).testScratch, "/tmp/t");
});
