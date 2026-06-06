#!/usr/bin/env node
// Render a per-platform npm subpackage tree ready for `npm publish`.
//
// Inputs:
//   --version <semver>     Version to publish (e.g. 0.9.2).
//   --platform <p>         npm `os` value: darwin | linux | win32.
//   --arch <a>             npm `cpu` value: x64 | arm64.
//   --target <triple>      Zig target triple used in the artifact name
//                          (e.g. aarch64-macos, x86_64-windows-gnu).
//   --dist <dir>           Dir containing the release artifact for this
//                          target. Expects either
//                          `cr-<version>-<target>.tar.gz` (POSIX) or
//                          `cr-<version>-<triple-without-gnu>.zip`
//                          (Windows), produced by release.yml's build job.
//   --out <dir>            Output dir to write the subpackage tree into.
//
// Output layout:
//   <out>/
//     package.json
//     bin/<cr|cr.exe>
//     README.md
//
// No network calls. Reads templates from
// packaging/npm/subpackage-template/.

import { argv, exit, stderr } from "node:process";
import { mkdirSync, readFileSync, writeFileSync, chmodSync, existsSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execSync } from "node:child_process";
import { createHash } from "node:crypto";

function fail(msg) {
  stderr.write(`prepare-subpackage: ${msg}\n`);
  exit(1);
}

function arg(name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx < 0 || idx === argv.length - 1) fail(`missing --${name}`);
  return argv[idx + 1];
}

const version = arg("version");
const platform = arg("platform");
const arch = arg("arch");
const target = arg("target");
const distDir = resolve(arg("dist"));
const outDir = resolve(arg("out"));

if (!["darwin", "linux", "win32"].includes(platform)) fail(`invalid --platform ${platform}`);
if (!["x64", "arm64"].includes(arch)) fail(`invalid --arch ${arch}`);

const here = dirname(fileURLToPath(import.meta.url));
const templateDir = resolve(here, "..", "subpackage-template");

const isWindows = platform === "win32";
const exeName = isWindows ? "cr.exe" : "cr";

// Locate the artifact produced by release.yml's build step.
let artifact;
if (isWindows) {
  const triple = target.replace(/-gnu$/, "");
  artifact = join(distDir, `cr-${version}-${triple}.zip`);
} else {
  artifact = join(distDir, `cr-${version}-${target}.tar.gz`);
}

if (!existsSync(artifact)) {
  stderr.write(`dist directory contents:\n`);
  for (const entry of readdirSync(distDir)) stderr.write(`  ${entry}\n`);
  fail(`expected artifact not found: ${artifact}`);
}

// Verify the artifact against its .sha256 sidecar before extracting.
// The sidecar comes from the same workflow run, but for a security-posture
// project we still re-hash here so the publish path has no implicit trust
// in either the artifact upload step or its consumer in this job.
const sidecar = `${artifact}.sha256`;
if (!existsSync(sidecar)) fail(`expected sidecar not found: ${sidecar}`);
const expectedSha = readFileSync(sidecar, "utf8").trim().split(/\s+/)[0];
const actualSha = createHash("sha256").update(readFileSync(artifact)).digest("hex");
if (expectedSha !== actualSha) {
  fail(`SHA256 mismatch for ${artifact}\n  expected: ${expectedSha}\n  actual:   ${actualSha}`);
}
stderr.write(`sha256 verified for ${artifact}\n`);

mkdirSync(join(outDir, "bin"), { recursive: true });

// Extract the cr binary out of the artifact straight into <out>/bin/.
if (isWindows) {
  execSync(`unzip -p "${artifact}" "${exeName}" > "${join(outDir, "bin", exeName)}"`, { stdio: "inherit", shell: "/bin/bash" });
} else {
  execSync(`tar -xzf "${artifact}" -C "${join(outDir, "bin")}" "${exeName}"`, { stdio: "inherit" });
  chmodSync(join(outDir, "bin", exeName), 0o755);
}

// Render package.json from template with platform/arch/version filled in.
// Note: no `bin` field — the binary is intentionally not linked by npm.
// The meta package's launcher (`@keton-id/cora`'s bin/cr.js) resolves
// this subpackage and execs the binary at `bin/<exe>` directly. Having
// `bin` here too would conflict with the meta's `cr` link on globals.
const pkgTemplate = readFileSync(join(templateDir, "package.json"), "utf8");
const pkg = JSON.parse(pkgTemplate);
pkg.name = `@keton-id/cora-${platform}-${arch}`;
pkg.version = version;
pkg.description = `Prebuilt cr binary for ${platform}/${arch}. Consumed via @keton-id/cora.`;
pkg.os = [platform];
pkg.cpu = [arch];
writeFileSync(join(outDir, "package.json"), JSON.stringify(pkg, null, 2) + "\n");

// Render README with placeholders substituted.
const readmeTemplate = readFileSync(join(templateDir, "README.md"), "utf8");
const readme = readmeTemplate
  .replaceAll("PLATFORM-ARCH", `${platform}-${arch}`)
  .replaceAll("PLATFORM / ARCH", `${platform} / ${arch}`);
writeFileSync(join(outDir, "README.md"), readme);

stderr.write(`prepared @keton-id/cora-${platform}-${arch}@${version} at ${outDir}\n`);
