// Imports the release's Developer ID certificate into a disposable keychain and writes the notary
// key, or removes both with `clean`. Runs only on GitHub Actions, mirroring Ace's release.
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { appendFileSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

function required(name: string): string {
	const value = process.env[name];
	if (!value) throw new Error(`Set ${name} before making a release`);
	return value;
}

if (process.env.GITHUB_ACTIONS !== "true") {
	throw new Error("This script only manages disposable GitHub Actions signing credentials");
}
const directory = join(required("RUNNER_TEMP"), "desktop-tools-signing");
const keychain = join(directory, "release.keychain-db");

function security(args: string[]) {
	const result = spawnSync("/usr/bin/security", args, { stdio: "pipe" });
	if (result.status !== 0) throw new Error(`Signing keychain setup failed at ${args[0]}`);
}

if (process.argv[2] === "clean") {
	spawnSync("/usr/bin/security", ["delete-keychain", keychain], { stdio: "ignore" });
	rmSync(directory, { recursive: true, force: true });
} else {
	mkdirSync(directory, { recursive: true, mode: 0o700 });
	const certificate = join(directory, "developer-id.p12");
	const key = join(directory, "notary.p8");
	writeFileSync(certificate, Buffer.from(required("DT_CERTIFICATE_P12"), "base64"), { mode: 0o600 });
	writeFileSync(key, required("DT_NOTARY_PRIVATE_KEY"), { mode: 0o600 });
	const password = randomUUID();
	security(["create-keychain", "-p", password, keychain]);
	security(["set-keychain-settings", "-lut", "21600", keychain]);
	security(["unlock-keychain", "-p", password, keychain]);
	security([
		"import",
		certificate,
		"-k",
		keychain,
		"-P",
		required("DT_CERTIFICATE_PASSWORD"),
		"-T",
		"/usr/bin/codesign",
		"-T",
		"/usr/bin/security",
	]);
	security(["set-key-partition-list", "-S", "apple-tool:,apple:", "-k", password, keychain]);
	security(["list-keychains", "-d", "user", "-s", keychain]);
	appendFileSync(required("GITHUB_ENV"), `DT_NOTARY_KEY=${key}\n`);
	rmSync(certificate);
}
