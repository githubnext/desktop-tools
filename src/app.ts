#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, cpSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

export const identifier = "dev.githubnext.desktop-tools";
/** Development builds get their own identity, nested under the release one, so they never replace its binaries. */
export const devIdentifier = `${identifier}.dev`;
const root = dirname(dirname(fileURLToPath(import.meta.url)));

function run(command: string[]) {
	const result = spawnSync(command[0]!, command.slice(1), { stdio: "inherit" });
	if (result.status !== 0) throw new Error(`Command failed: ${command.join(" ")}`);
}

/** Builds the native products into `<out>/build` and assembles an unsigned `<out>/Desktop Tools.app`, or `Desktop Tools Dev.app` for `dev`. */
export function assemble(out: string, scratch?: string, dev = false) {
	const build = join(out, "build");
	run(["node", join(root, "dist", "build.js"), "--out", build, ...(scratch ? ["--scratch", scratch] : [])]);
	const name = dev ? "Desktop Tools Dev" : "Desktop Tools";
	const app = join(out, `${name}.app`);
	rmSync(app, { recursive: true, force: true });
	const bin = join(app, "Contents", "MacOS");
	mkdirSync(bin, { recursive: true });
	mkdirSync(join(app, "Contents", "Resources"), { recursive: true });
	for (const name of ["desktop-tools-app", "libDesktopTools.dylib", "desktop-tools-client"]) {
		copyFileSync(join(build, name), join(bin, name));
	}
	chmodSync(join(bin, "desktop-tools-app"), 0o755);
	chmodSync(join(bin, "desktop-tools-client"), 0o755);
	cpSync(join(build, "Licenses"), join(app, "Contents", "Resources", "Licenses"), { recursive: true });
	copyFileSync(join(root, "native", "resources", "AppIcon.icns"), join(app, "Contents", "Resources", "AppIcon.icns"));
	const { version } = JSON.parse(readFileSync(join(root, "package.json"), "utf8")) as { version: string };
	writeFileSync(
		join(app, "Contents", "Info.plist"),
		`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>${dev ? devIdentifier : identifier}</string>
	<key>CFBundleName</key><string>${name}</string>
	<key>CFBundleDisplayName</key><string>${name}</string>
	<key>CFBundleExecutable</key><string>desktop-tools-app</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${version}</string>
	<key>CFBundleVersion</key><string>${version}</string>
	<key>LSMinimumSystemVersion</key><string>15.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
`,
	);
	// Binaries carry an @loader_path/../Frameworks rpath for any Swift libraries the deployment target needs.
	run([
		"xcrun",
		"swift-stdlib-tool",
		"--copy",
		"--scan-folder",
		bin,
		"--platform",
		"macosx",
		"--destination",
		join(app, "Contents", "Frameworks"),
	]);
	return app;
}

/** Signs inside out; the client's exact identifier, the bundle's plus `.desktop-client`, is what the runtime admits. */
export function sign(app: string, identity: string, release: boolean) {
	const plist = join(app, "Contents", "Info.plist");
	const bundle = spawnSync("plutil", ["-extract", "CFBundleIdentifier", "raw", "-o", "-", plist], { encoding: "utf8" }).stdout.trim();
	if (!bundle) throw new Error(`No CFBundleIdentifier in ${plist}`);
	const codesign = ["codesign", "--force", "--sign", identity, ...(release ? ["--options", "runtime", "--timestamp"] : [])];
	const frameworks = join(app, "Contents", "Frameworks");
	for (const name of readdirSync(frameworks, { withFileTypes: true }).filter((entry) => entry.isFile())) {
		run([...codesign, join(frameworks, name.name)]);
	}
	const bin = join(app, "Contents", "MacOS");
	run([...codesign, join(bin, "libDesktopTools.dylib")]);
	run([...codesign, "--identifier", `${bundle}.desktop-client`, join(bin, "desktop-tools-client")]);
	run([...codesign, app]);
	run(["codesign", "--verify", "--deep", "--strict", app]);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
	const { values } = parseArgs({
		options: {
			out: { type: "string" },
			scratch: { type: "string" },
			identity: { type: "string" },
			release: { type: "boolean", default: false },
		},
		strict: true,
	});
	if (!values.out) {
		throw new Error("Usage: desktop-tools-app --out <directory> [--scratch <directory>] [--identity <codesign identity> [--release]]");
	}
	const app = assemble(resolve(values.out), values.scratch && resolve(values.scratch));
	if (values.identity) sign(app, values.identity, values.release);
	console.log(app);
}
