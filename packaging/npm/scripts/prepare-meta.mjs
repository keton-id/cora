#!/usr/bin/env node
// Render the @keton-id/cora meta npm package ready for `npm publish`.
//
// Inputs:
//   --src <dir>         Source dir containing the meta template tree
//                       (packaging/npm/meta).
//   --out <dir>         Output dir for the rendered tree.
//
// Versioning model (lockstep-by-state, not lockstep-by-tag):
//
// - The meta is a thin launcher whose only payload is the
//   optionalDependencies map. We want every meta publish to reflect
//   the CURRENT state of the six subpackages on npm, so that
//   `npm i -g @keton-id/cora@latest` always pulls the freshest binary
//   for the host. To support out-of-step per-OS releases (e.g. a
//   Windows-only fix advances win32 subpackages while macOS / Linux
//   stay where they were), the meta must be re-publishable without
//   requiring all three OSes to bump in lockstep.
//
// - Meta version is therefore monotonic and decoupled from the
//   `v*` upstream release version: read the current registry value
//   for `@keton-id/cora`, bump the patch. On first ever publish
//   (registry returns nothing), start at 0.0.1.
//
// - optionalDependencies pins are queried live from the npm registry
//   for each of the six `@keton-id/cora-<platform>-<arch>` packages
//   and pinned to their actual current version. If a subpackage has
//   never been published, it is omitted; npm will then fall through
//   to the meta launcher's "no prebuilt binary" error on that host.

import { argv, exit, stderr } from "node:process";
import { readFileSync, writeFileSync, mkdirSync, cpSync } from "node:fs";
import { resolve, join } from "node:path";
import { execSync } from "node:child_process";

function fail(msg) {
  stderr.write(`prepare-meta: ${msg}\n`);
  exit(1);
}

function arg(name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx < 0 || idx === argv.length - 1) fail(`missing --${name}`);
  return argv[idx + 1];
}

const srcDir = resolve(arg("src"));
const outDir = resolve(arg("out"));

// npm view returns empty stdout (and exit 0) when a package does not exist
// and a non-zero exit with "E404" when the version is missing. We only
// need the happy path — return null on any failure.
function npmViewVersion(name) {
  try {
    const out = execSync(`npm view ${JSON.stringify(name)} version`, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
    return out || null;
  } catch {
    return null;
  }
}

function bumpPatch(semver) {
  // Strip any prerelease/build metadata before bumping — the meta is
  // publish-only, never preserves a prerelease channel.
  const base = semver.split("-")[0].split("+")[0];
  const parts = base.split(".").map((n) => parseInt(n, 10));
  if (parts.length !== 3 || parts.some((n) => Number.isNaN(n))) {
    fail(`cannot bump non-semver meta version: ${semver}`);
  }
  parts[2] += 1;
  return parts.join(".");
}

const META_NAME = "@keton-id/cora";
const SUBPACKAGES = [
  "@keton-id/cora-darwin-x64",
  "@keton-id/cora-darwin-arm64",
  "@keton-id/cora-linux-x64",
  "@keton-id/cora-linux-arm64",
  "@keton-id/cora-win32-x64",
  "@keton-id/cora-win32-arm64",
];

const currentMeta = npmViewVersion(META_NAME);
const metaVersion = currentMeta ? bumpPatch(currentMeta) : "0.0.1";
stderr.write(`current meta: ${currentMeta ?? "<unpublished>"} -> bumping to ${metaVersion}\n`);

const optionalDependencies = {};
for (const name of SUBPACKAGES) {
  const v = npmViewVersion(name);
  if (v) {
    optionalDependencies[name] = v;
    stderr.write(`  pin ${name}@${v}\n`);
  } else {
    stderr.write(`  skip ${name} (not yet published)\n`);
  }
}

if (Object.keys(optionalDependencies).length === 0) {
  fail(`no subpackages published yet — refuse to publish meta with empty optionalDependencies`);
}

mkdirSync(outDir, { recursive: true });
cpSync(srcDir, outDir, { recursive: true });

const pkgPath = join(outDir, "package.json");
const pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
pkg.version = metaVersion;
pkg.optionalDependencies = optionalDependencies;
writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + "\n");

stderr.write(`prepared ${META_NAME}@${metaVersion} at ${outDir}\n`);
