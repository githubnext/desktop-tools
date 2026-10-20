import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { test } from "node:test";

// Scripts aren't type-checked, so an export removed from src/ only fails when the script runs (the 0.11.0 release did).
test("every name a script imports from dist/ is exported", async () => {
	const dir = new URL("../scripts/", import.meta.url);
	for (const file of readdirSync(dir).filter((name) => /\.(ts|mjs|js)$/.test(name))) {
		const source = readFileSync(new URL(file, dir), "utf8");
		for (const [, names, module] of source.matchAll(/import\s*\{([^}]+)\}\s*from\s*"\.\.\/(dist\/[\w-]+\.js)"/g)) {
			const exports = await import(new URL(`../${module}`, import.meta.url));
			for (const name of names.split(",").map((part) => part.trim().split(/\s+as\s+/)[0]).filter(Boolean)) {
				assert.ok(name in exports, `scripts/${file} imports ${name} from ${module}, which doesn't export it`);
			}
		}
	}
});

// native2 builds the menu bar app from its own copy until native/ is removed (#143), so the two mustn't drift.
test("native/ and native2 build the same menu bar app", () => {
	const copies = ["../native/sources/app/", "../native2/Sources/desktop-tools-app/"].map((path) => new URL(path, import.meta.url));
	const [names, others] = copies.map((dir) => readdirSync(dir).sort());
	assert.deepEqual(others, names);
	for (const name of names) {
		assert.equal(readFileSync(new URL(name, copies[1]), "utf8"), readFileSync(new URL(name, copies[0]), "utf8"), `${name} differs`);
	}
});
