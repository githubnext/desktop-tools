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
