#!/usr/bin/env node
// Render the @keton-id/cora meta npm package ready for `npm publish`.
//
// Inputs:
//   --version <semver>   The release version (no `v` prefix). Becomes the
//                        meta package's own version. Passed by release.yml
//                        from the mirror tag, so meta versions stay in
//                        lockstep with the release semver and are
//                        monotonic by construction (every release is a
//                        new version → no 409 collisions).
//   --src <dir>          Source dir containing the meta template tree
//                        (packaging/npm/meta).
//   --out <dir>          Output dir for the rendered tree.
//
// optionalDependencies pins are queried live from the npm registry for
// each of the six `@keton-id/cora-<platform>-<arch>` packages and pinned
// to their actual current dist-tag `latest`. Subpackages that have never
// been published are skipped; an out-of-step per-OS release (e.g.
// Windows-only fix advances win32 subpackages while macOS / Linux stay
// where they were) ships cleanly because every other OS keeps its
// existing registry version.

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

const version = arg("version");
const srcDir = resolve(arg("src"));
const outDir = resolve(arg("out"));

if (!/^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$/.test(version)) {
  fail(`--version must be plain semver (got: ${version})`);
}

// `npm view` exits 0 with empty stdout when the package is missing and
// non-zero with an "E404" message when the version is missing. We only
// care about the happy path — return null on any failure.
function npmViewLatest(name) {
  try {
    const out = execSync(`npm view ${JSON.stringify(name)} dist-tags.latest`, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
    return out || null;
  } catch {
    return null;
  }
}

const SUBPACKAGES = [
  "@keton-id/cora-darwin-x64",
  "@keton-id/cora-darwin-arm64",
  "@keton-id/cora-linux-x64",
  "@keton-id/cora-linux-arm64",
  "@keton-id/cora-win32-x64",
  "@keton-id/cora-win32-arm64",
];

const optionalDependencies = {};
for (const name of SUBPACKAGES) {
  const v = npmViewLatest(name);
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
pkg.version = version;
pkg.optionalDependencies = optionalDependencies;
writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + "\n");

stderr.write(`prepared @keton-id/cora@${version} at ${outDir}\n`);
