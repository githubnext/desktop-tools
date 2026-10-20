// Builds Desktop Tools.app, signs it inside-out, notarizes and staples the app and its DMG, and
// verifies both with Gatekeeper, mirroring Ace's desktop release. Publishing is the workflow's job.
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, rmSync, symlinkSync } from "node:fs";
import { basename, join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

import { assemble, sign } from "../dist/app.js";

function required(name: string): string {
	const value = process.env[name];
	if (!value) throw new Error(`Set ${name} before making a release`);
	return value;
}

function log(message: string): void {
	console.log(`${new Date().toISOString()} ${message}`);
}

function run(command: string[]): void {
	const result = spawnSync(command[0]!, command.slice(1), { stdio: "inherit" });
	if (result.status !== 0) throw new Error(`${command[0]} failed with exit code ${result.status}`);
}

// Apple's ticket lookup intermittently drops connections (stapler exit 68) after notarization succeeds.
async function stapler(action: "staple" | "validate", path: string): Promise<void> {
	for (let attempt = 1;; attempt++) {
		try {
			return run(["xcrun", "stapler", action, path]);
		} catch (error) {
			if (attempt === 5) throw error;
			const seconds = 20 * 2 ** (attempt - 1);
			log(`stapler ${action} attempt ${attempt} failed; retrying in ${seconds}s`);
			await sleep(seconds * 1000);
		}
	}
}

const root = join(import.meta.dirname, "..");
const { version } = JSON.parse(readFileSync(join(root, "package.json"), "utf8")) as {
	version: string;
};
const changes = spawnSync("git", ["status", "--porcelain"], { cwd: root, encoding: "utf8" });
if (changes.status !== 0 || changes.stdout) {
	throw new Error("Commit the lane's changes before making a release");
}
// The app runs the pure Swift host (#143) unless DT_STACK=native switches the release back to Peekaboo's.
const stack = process.env.DT_STACK ?? "native2";
if (stack !== "native2" && stack !== "native") throw new Error("DT_STACK must be native2 or native");
const identity = required("DT_CODESIGN_IDENTITY");
const auth = [
	"--key",
	required("DT_NOTARY_KEY"),
	"--key-id",
	required("DT_NOTARY_KEY_ID"),
	"--issuer",
	required("DT_NOTARY_ISSUER"),
];

function notary(args: string[]) {
	return spawnSync("xcrun", ["notarytool", ...args, ...auth, "--output-format", "json"], {
		encoding: "utf8",
	});
}

function notarize(path: string): void {
	const submitted = notary(["submit", path]);
	if (submitted.status !== 0) throw new Error(`Notarization upload failed: ${submitted.stderr}`);
	const { id } = JSON.parse(submitted.stdout) as { id: string };
	log(`Notarization submitted for ${basename(path)}: ${id}`);
	// Credentials are named by environment variable so the printed commands are safe to share.
	const check = [
		`xcrun notarytool info ${id} --key "$DT_NOTARY_KEY" --key-id "$DT_NOTARY_KEY_ID" --issuer "$DT_NOTARY_ISSUER"`,
		`xcrun notarytool log ${id} --key "$DT_NOTARY_KEY" --key-id "$DT_NOTARY_KEY_ID" --issuer "$DT_NOTARY_ISSUER"`,
	].join("\n");
	// The service keeps processing past the wait's timeout, so info decides the outcome.
	notary(["wait", id, "--timeout", "20m"]);
	const info = notary(["info", id]);
	if (info.status !== 0) {
		throw new Error(`Notarization ${id} status is unavailable: ${info.stderr}\nCheck it later with:\n${check}`);
	}
	const { status } = JSON.parse(info.stdout) as { status: string };
	if (status !== "Accepted") {
		throw new Error(`Notarization ${id} finished with status ${status}. Check it with:\n${check}`);
	}
	log(`Notarization accepted: ${id}`);
}

const staging = join(root, ".build", `release-${randomUUID()}`);
const output = join(root, "build", "release");
mkdirSync(staging, { recursive: true });
mkdirSync(output, { recursive: true });
try {
	log(`==> Build (${stack})`);
	const app = assemble(join(staging, "app"), join(root, ".build", "native"), false, stack === "native2");
	log("==> App signing");
	sign(app, identity, true);
	const zip = join(staging, "notarize.zip");
	run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, zip]);
	log("==> App notarization");
	notarize(zip);
	await stapler("staple", app);
	run(["/usr/sbin/spctl", "--assess", "--type", "execute", app]);
	log("==> DMG");
	const volume = join(staging, "volume");
	mkdirSync(volume);
	run(["/usr/bin/ditto", app, join(volume, basename(app))]);
	symlinkSync("/Applications", join(volume, "Applications"));
	const dmg = join(output, `desktop-tools-${version}-macos-arm64.dmg`);
	rmSync(dmg, { force: true });
	run(["/usr/bin/hdiutil", "create", "-volname", "Desktop Tools", "-srcfolder", volume, "-format", "UDZO", dmg]);
	run(["/usr/bin/codesign", "--force", "--sign", identity, "--timestamp", dmg]);
	log("==> DMG notarization");
	notarize(dmg);
	await stapler("staple", dmg);
	await stapler("validate", dmg);
	run(["/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature", dmg]);
	log(`Release ready: ${dmg}`);
} finally {
	rmSync(staging, { recursive: true, force: true });
}
