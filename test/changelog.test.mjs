import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import { changelogSection } from "../scripts/changelog.ts";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const { version } = JSON.parse(read("package.json"));
const changelog = read("CHANGELOG.md");

test("the package version has CHANGELOG entries and a compare link, for its release notes", () => {
	assert.ok(changelogSection(changelog, version), `CHANGELOG.md has no entries under "## [${version}]"`);
	assert.match(changelog, new RegExp(`^## \\[${version.replaceAll(".", "\\.")}\\] - \\d{4}-\\d{2}-\\d{2}$`, "m"), "the version heading needs its release date");
	assert.match(changelog, new RegExp(`^\\[${version.replaceAll(".", "\\.")}\\]: https://`, "m"), "the version needs a link definition");
	assert.match(changelog, /^## \[Unreleased\]$/m);
});

test("a section ends at the next version, and an empty one counts as missing", () => {
	const text = "## [Unreleased]\n\n## [1.1.0] - 2026-01-02\n\n### Added\n\n- New.\n\n## [1.0.0] - 2026-01-01\n\n- Old.\n\n[1.1.0]: https://example.com\n";
	assert.equal(changelogSection(text, "1.1.0"), "### Added\n\n- New.");
	assert.equal(changelogSection(text, "1.0.0"), "- Old.");
	assert.equal(changelogSection(text, "Unreleased"), null);
	assert.equal(changelogSection(text, "1.0"), null);
});
