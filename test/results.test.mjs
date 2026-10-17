import assert from "node:assert/strict";
import { test } from "node:test";
import { errorMessage, parseResult } from "../dist/results.js";

test("errorMessage reads an Error's message and stringifies anything else", () => {
	assert.equal(errorMessage(new Error("The window closed.")), "The window closed.");
	assert.equal(errorMessage("plain"), "plain");
	assert.equal(errorMessage(42), "42");
});

test("errorMessage bounds a runaway message to 2000 characters", () => {
	assert.equal(errorMessage(new Error("x".repeat(5000))).length, 2000);
});

test("parseResult returns the result text's JSON object", () => {
	assert.deepEqual(parseResult({ text: '{"apps":[],"count":0}' }), { apps: [], count: 0 });
	assert.throws(() => parseResult({ text: "not json" }), SyntaxError);
});
