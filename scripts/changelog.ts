// Prints one version's CHANGELOG.md section, without its heading, as that release's notes.
// Usage: node scripts/changelog.ts [version], defaulting to package.json's version.
import { readFileSync } from "node:fs";

const escape = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/** The body of `## [version]`, up to the next `## ` heading or the link definitions; null when absent or empty. */
export function changelogSection(changelog: string, version: string): string | null {
	const heading = new RegExp(`^## \\[${escape(version)}\\](?: - \\d{4}-\\d{2}-\\d{2})?\\s*$`, "m");
	const start = heading.exec(changelog);
	if (!start) return null;
	const rest = changelog.slice(start.index + start[0].length);
	const end = rest.search(/^(## |\[[^\]]+\]: )/m);
	const body = (end < 0 ? rest : rest.slice(0, end)).trim();
	return /^- /m.test(body) ? body : null;
}

if (import.meta.main) {
	const root = new URL("../", import.meta.url);
	const version = process.argv[2] ?? JSON.parse(readFileSync(new URL("package.json", root), "utf8")).version;
	const section = changelogSection(readFileSync(new URL("CHANGELOG.md", root), "utf8"), version);
	if (!section) {
		console.error(`CHANGELOG.md has no entries under "## [${version}]".`);
		process.exit(1);
	}
	console.log(section);
}
