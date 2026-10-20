#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
const { values } = parseArgs({
    options: { out: { type: "string" }, scratch: { type: "string" }, native2: { type: "boolean", default: false } },
    strict: true,
});
if (!values.out) {
    throw new Error("Usage: desktop-tools-build --out <directory> [--scratch <directory>] [--native2]");
}
if (process.platform !== "darwin")
    throw new Error("Native desktop tools build on macOS");
const root = dirname(dirname(fileURLToPath(import.meta.url)));
const native = join(root, "native");
const out = resolve(values.out);
const scratch = resolve(values.scratch ?? join(native, ".build"));
// Peekaboo 4.8.0 with our changes, vendored; git diff peekaboo-upstream-4d43dc9 -- native/vendor/Peekaboo shows them.
const peekaboo = join(native, "vendor", "Peekaboo");
function spawn(command, env) {
    return spawnSync(command[0], command.slice(1), { encoding: "utf8", env: env ?? process.env });
}
function run(command) {
    const result = spawnSync(command[0], command.slice(1), { stdio: "inherit" });
    if (result.status !== 0)
        throw new Error(`Command failed: ${command.join(" ")}`);
}
const swift = spawn(["xcrun", "swift", "--version"]);
const version = /Swift version (\d+)\.(\d+)/.exec(swift.stdout ?? "");
if (swift.status !== 0 || !version
    || Number(version[1]) * 100 + Number(version[2]) < 602)
    throw new Error("Native desktop tools require Xcode with Swift 6.2 or newer");
const package_ = ["--package-path", native, "--scratch-path", scratch];
run(["xcrun", "swift", "package", ...package_, "--force-resolved-versions", "resolve"]);
const resolved = JSON.parse(readFileSync(join(native, "Package.resolved"), "utf8"));
const checkouts = join(scratch, "checkouts");
const dependencies = new Map(readdirSync(checkouts).map((name) => [name.toLowerCase(), name]));
// The embedded host silently drops operations outside Peekaboo's embedded allowlist, so a new operation
// reached clients only as "not supported". Fail the build instead.
const operationList = (source, start) => {
    const from = source.indexOf(start);
    if (from < 0)
        throw new Error(`Cannot find ${start} in the native sources`);
    const block = source.slice(from + start.length, source.indexOf("]", from + start.length));
    return new Set([...block.matchAll(/\.(\w+)/g)].map((match) => match[1]));
};
const policy = readFileSync(join(peekaboo, "Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeOperation+Policy.swift"), "utf8");
const remote = operationList(policy, "remoteDefaultAllowlist: Set<PeekabooBridgeOperation> = [");
const excluded = operationList(policy, "remoteDefaultAllowlist.subtracting([");
const requested = operationList(readFileSync(join(native, "sources", "runtime", "runtime.swift"), "utf8"), "allowedOperations: [");
const dropped = [...requested].filter((name) => !remote.has(name) || excluded.has(name));
if (dropped.length) {
    throw new Error(`The embedded host would drop these allowed operations: ${dropped.join(", ")}`);
}
const release = [
    "--configuration",
    "release",
    "--force-resolved-versions",
    // App bundles keep any needed Swift runtime libraries in Contents/Frameworks.
    "-Xlinker",
    "-rpath",
    "-Xlinker",
    "@loader_path/../Frameworks",
];
const build = ["xcrun", "swift", "build", ...package_, ...release];
run(build);
const location = spawn([...build, "--show-bin-path"]);
if (location.status !== 0)
    throw new Error("Cannot locate the native build products");
const products = location.stdout.trim();
mkdirSync(out, { recursive: true });
for (const name of ["libDesktopTools.dylib", "desktop-tools-client", "desktop-tools-app"]) {
    copyFileSync(join(products, name), join(out, name));
}
// The pure Swift host (#143) exports the same C ABI, so the app runs it in place of native/'s runtime and client.
if (values.native2) {
    const native2 = ["xcrun", "swift", "build", "--package-path", join(root, "native2"), ...release];
    run(native2);
    const located = spawn([...native2, "--show-bin-path"]);
    if (located.status !== 0)
        throw new Error("Cannot locate the native2 build products");
    for (const name of ["libDesktopTools.dylib", "desktop-tools-client", "desktop-tools-mcp"]) {
        copyFileSync(join(located.stdout.trim(), name), join(out, name));
    }
}
else {
    // native/ has no MCP binary, so one left by a native2 build would be bundled with the wrong host.
    rmSync(join(out, "desktop-tools-mcp"), { force: true });
}
// Every artifact carries the notices of what it links; other files in <out>/Licenses stay.
const licenses = join(out, "Licenses");
const notices = (source, identity) => {
    const files = readdirSync(source).filter((name) => /^(LICENSE|LICENCE|NOTICE)([.-].*)?$/i.test(name));
    if (!files.length)
        throw new Error(`The native dependency ${identity} has no license file`);
    mkdirSync(join(licenses, identity), { recursive: true });
    for (const name of files) {
        // Checked-out notices are read-only and copies keep that mode, so replace each one.
        rmSync(join(licenses, identity, name), { force: true });
        copyFileSync(join(source, name), join(licenses, identity, name));
    }
};
notices(root, "desktop-tools");
notices(peekaboo, "peekaboo");
for (const { identity } of resolved.pins) {
    const name = dependencies.get(identity);
    if (!name)
        throw new Error(`The resolved native dependency ${identity} is missing`);
    notices(join(checkouts, name), identity);
}
