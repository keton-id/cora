#!/usr/bin/env node
// Render and publish the @keton-id/cora meta npm package.
//
// Inputs:
//   --version <semver>   Release version (no `v` prefix) for the meta
//                        package. The publish is idempotent for an
//                        existing version with the same platform pins.
//   --src <dir>          Source dir containing the meta template tree
//                        (packaging/npm/meta).
//   --out <dir>          Output dir for the rendered tree (used as
//                        cwd for `npm publish`).
//   --registry <url>     Optional registry URL for all `npm view` and
//                        `npm publish` calls. Release CI targets npmjs.org
//                        using npm Trusted Publishing (OIDC).
//
// optionalDependencies pins are queried live from npmjs.org for each of
// the six `@keton-id/cora-<platform>-<arch>` packages. Each query
// distinguishes a legitimate "never published" (E404) from a transient
// failure; transient errors fail the job instead of silently dropping a
// platform from the launcher.
//

import { argv, exit, stderr, stdout } from "node:process";
import { readFileSync, writeFileSync, mkdirSync, cpSync, rmSync } from "node:fs";
import { resolve, join } from "node:path";
import { spawnSync } from "node:child_process";

function fail(msg) {
  stderr.write(`prepare-meta: ${msg}\n`);
  exit(1);
}

function arg(name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx < 0 || idx === argv.length - 1) fail(`missing --${name}`);
  return argv[idx + 1];
}

function optArg(name) {
  const idx = argv.indexOf(`--${name}`);
  if (idx < 0 || idx === argv.length - 1) return null;
  return argv[idx + 1];
}

const releaseVersion = arg("version");
const srcDir = resolve(arg("src"));
const outDir = resolve(arg("out"));
const registry = optArg("registry");
const registryArgs = registry ? ["--registry", registry] : [];

if (!/^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$/.test(releaseVersion)) {
  fail(`--version must be plain semver (got: ${releaseVersion})`);
}


// E404 (or "404 Not Found") is a definitive "package or version does
// not exist" from the registry — return null so the caller treats it
// as a legitimate absence. Anything else is a transient failure (DNS,
// 502, etc.) and we re-throw so the job goes red and can be retried.
function isNotFound(stderrText) {
  return /\bE404\b|404 Not Found|not in this registry/i.test(stderrText || "");
}

function npmRun(args, opts = {}) {
  return spawnSync("npm", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    ...opts,
  });
}

function npmViewVersion(name) {
  const r = npmRun(["view", name, "dist-tags.latest", ...registryArgs]);
  if (r.status === 0) return (r.stdout || "").trim() || null;
  if (isNotFound(r.stderr)) return null;
  throw new Error(`npm view ${name} dist-tags.latest failed:\n${r.stderr || r.error?.message}`);
}

function npmViewOptionalDependencies(name, version) {
  const r = npmRun(["view", `${name}@${version}`, "optionalDependencies", "--json", ...registryArgs]);
  if (r.status === 0) {
    const text = (r.stdout || "").trim();
    if (!text) return null;
    try {
      return JSON.parse(text);
    } catch {
      // `npm view <name>@<v> optionalDependencies` returns an empty
      // string when the field is absent on that exact version.
      return null;
    }
  }
  if (isNotFound(r.stderr)) return null;
  throw new Error(`npm view ${name}@${version} optionalDependencies failed:\n${r.stderr || r.error?.message}`);
}

const SUBPACKAGES = [
  "@keton-id/cora-darwin-x64",
  "@keton-id/cora-darwin-arm64",
  "@keton-id/cora-linux-x64",
  "@keton-id/cora-linux-arm64",
  "@keton-id/cora-win32-x64",
  "@keton-id/cora-win32-arm64",
];

function collectPins() {
  const pins = {};
  for (const name of SUBPACKAGES) {
    const v = npmViewVersion(name);
    if (v) {
      pins[name] = v;
      stderr.write(`  pin ${name}@${v}\n`);
    } else {
      stderr.write(`  skip ${name} (not yet published)\n`);
    }
  }
  return pins;
}

function pinsEqual(a, b) {
  if (!a || !b) return false;
  const ka = Object.keys(a).sort();
  const kb = Object.keys(b).sort();
  if (ka.length !== kb.length) return false;
  for (let i = 0; i < ka.length; i++) {
    if (ka[i] !== kb[i]) return false;
    if (a[ka[i]] !== b[ka[i]]) return false;
  }
  return true;
}

function renderTree(version, pins) {
  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });
  cpSync(srcDir, outDir, { recursive: true });

  const pkgPath = join(outDir, "package.json");
  const pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
  pkg.version = version;
  pkg.optionalDependencies = pins;
  writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + "\n");
}

// npm publish exits with a version conflict when this release is already
// present. Treat identical pins as an idempotent rerun; never invent a
// second package version that diverges from the Cora release tag.
function attemptPublish() {
  const r = npmRun(["publish", "--access", "public", ...registryArgs], {
    cwd: outDir,
    stdio: ["ignore", "pipe", "pipe"],
  });
  stdout.write(r.stdout || "");
  stderr.write(r.stderr || "");

  if (r.status === 0) return;

  const text = (r.stderr || "") + (r.stdout || "");
  if (/EPUBLISHCONFLICT|cannot publish over|previously published versions|version not allowed/i.test(text)) {
    const existing = npmViewOptionalDependencies(META, releaseVersion);
    if (pinsEqual(existing, pins)) {
      stderr.write(`${META}@${releaseVersion} already published with identical pins — idempotent exit\n`);
      return;
    }
    fail(`${META}@${releaseVersion} already exists with different platform pins; refusing to publish a mismatched version`);
  }
  throw new Error(`npm publish failed:\n${text || r.error?.message}`);
}

const META = "@keton-id/cora";
const pins = collectPins();
if (Object.keys(pins).length === 0) {
  fail(`no subpackages published yet — refuse to publish meta with empty optionalDependencies`);
}

stderr.write(`\n=== publishing ${META}@${releaseVersion} ===\n`);
renderTree(releaseVersion, pins);
attemptPublish();
