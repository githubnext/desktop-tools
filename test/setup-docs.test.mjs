import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const { version, bin } = JSON.parse(read("package.json"));

test("the setup docs pin the package's own release and run its MCP bin", () => {
	for (const path of ["README.md", "docs/mcp.md"]) {
		const pins = [...read(path).matchAll(/github:githubnext\/desktop-tools#v([\w.-]+) desktop-tools-mcp|"--package=github:githubnext\/desktop-tools#v([\w.-]+)", "desktop-tools-mcp"/g)];
		assert.ok(pins.length > 0, `${path} has no npx setup`);
		for (const pin of pins) assert.equal(pin[1] ?? pin[2], version, `${path} pins v${pin[1] ?? pin[2]}, not v${version}`);
	}
	assert.equal(bin["desktop-tools-mcp"], "dist/mcp.js");
});
