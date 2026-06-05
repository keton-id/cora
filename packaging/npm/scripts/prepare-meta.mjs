#!/usr/bin/env node
// Render the @keton-id/cora meta npm package ready for `npm publish`.
//
// Inputs:
//   --versions <path>   Path to .versions.json at repo root. Holds the
//                       three current per-OS versions managed by
//                       release-please.
//   --src <dir>         Source dir containing the meta template tree
//                       (packaging/npm/meta).
//   --out <dir>         Output dir for the rendered tree.
//
// The meta version is set to the maximum of the three per-OS semver
// values so that `npm i -g @keton-id/cora@latest` always pulls the
// freshest binary for the host. optionalDependencies are pinned to
// the exact per-OS version: an older OS subpackage is not "latest" by
// accident.

import { argv, exit, stderr } from "node:process";
import { readFileSync, writeFileSync, mkdirSync, cpSync } from "node:fs";
import { resolve, join } from "node:path";

function fail(msg) {
  stderr.write(`prepare-meta: ${msg}\n`);
  exit(1);
}

function arg(name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx < 0 || idx === argv.length - 1) fail(`missing --${name}`);
  return argv[idx + 1];
}

const versionsPath = resolve(arg("versions"));
const srcDir = resolve(arg("src"));
const outDir = resolve(arg("out"));

const versions = JSON.parse(readFileSync(versionsPath, "utf8"));
const { macos, linux, windows } = versions;
if (!macos || !linux || !windows) fail(`incomplete .versions.json: ${JSON.stringify(versions)}`);

// Pure-semver comparator. Pre-release suffixes (e.g. "-alpha.1") rank
// below the same base version per semver 2.0.0. We restrict the meta
// to stable, since prereleases never publish to npm — so all inputs
// here should be plain X.Y.Z.
function cmp(a, b) {
  const [av, ap = ""] = a.split("-");
  const [bv, bp = ""] = b.split("-");
  const aa = av.split(".").map(Number);
  const bb = bv.split(".").map(Number);
  for (let i = 0; i < 3; i++) {
    if (aa[i] !== bb[i]) return aa[i] - bb[i];
  }
  // Equal base versions: stable (no suffix) > prerelease.
  if (ap === "" && bp !== "") return 1;
  if (ap !== "" && bp === "") return -1;
  return ap.localeCompare(bp);
}

const metaVersion = [macos, linux, windows].sort(cmp).at(-1);

mkdirSync(outDir, { recursive: true });
cpSync(srcDir, outDir, { recursive: true });

// Patch package.json in the copied tree.
const pkgPath = join(outDir, "package.json");
const pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
pkg.version = metaVersion;
pkg.optionalDependencies = {
  "@keton-id/cora-darwin-x64": macos,
  "@keton-id/cora-darwin-arm64": macos,
  "@keton-id/cora-linux-x64": linux,
  "@keton-id/cora-linux-arm64": linux,
  "@keton-id/cora-win32-x64": windows,
  "@keton-id/cora-win32-arm64": windows,
};
writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + "\n");

stderr.write(`prepared @keton-id/cora@${metaVersion} (macos=${macos} linux=${linux} windows=${windows}) at ${outDir}\n`);
