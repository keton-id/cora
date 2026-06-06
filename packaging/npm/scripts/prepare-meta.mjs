#!/usr/bin/env node
// Render and publish the @keton-id/cora meta npm package.
//
// Inputs:
//   --version <semver>   The release version (no `v` prefix). Becomes
//                        the meta's initial candidate version. A
//                        coordinated multi-OS stable release (e.g.
//                        v1.0.0) fans out to up to three mirror tags
//                        at the same version, which triggers three
//                        parallel publish-npm-meta jobs against the
//                        same `@keton-id/cora@<version>`. The
//                        bump-on-conflict loop below resolves that
//                        race: the first publisher wins, and the
//                        others either no-op idempotently (identical
//                        pins) or fall through to a bumped patch
//                        (different pins).
//   --src <dir>          Source dir containing the meta template tree
//                        (packaging/npm/meta).
//   --out <dir>          Output dir for the rendered tree (used as
//                        cwd for `npm publish`).
//
// optionalDependencies pins are queried live from the npm registry
// for each of the six `@keton-id/cora-<platform>-<arch>` packages.
// Each query distinguishes a legitimate "never published" (E404)
// from a transient failure (network blip, registry hiccup): the
// former returns null and the platform is omitted, the latter
// throws so the job fails loudly and can be retried — avoids
// silently shipping a meta that drops a platform on `@latest`.

import { argv, env, exit, stderr, stdout } from "node:process";
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

const releaseVersion = arg("version");
const srcDir = resolve(arg("src"));
const outDir = resolve(arg("out"));

if (!/^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$/.test(releaseVersion)) {
  fail(`--version must be plain semver (got: ${releaseVersion})`);
}

function bumpPatch(semver) {
  const base = semver.split("-")[0].split("+")[0];
  const parts = base.split(".").map((n) => parseInt(n, 10));
  if (parts.length !== 3 || parts.some((n) => Number.isNaN(n))) {
    fail(`cannot bump non-semver: ${semver}`);
  }
  parts[2] += 1;
  return parts.join(".");
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
  const r = npmRun(["view", name, "dist-tags.latest"]);
  if (r.status === 0) return (r.stdout || "").trim() || null;
  if (isNotFound(r.stderr)) return null;
  throw new Error(`npm view ${name} dist-tags.latest failed:\n${r.stderr || r.error?.message}`);
}

function npmViewOptionalDependencies(name, version) {
  const r = npmRun(["view", `${name}@${version}`, "optionalDependencies", "--json"]);
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

// `npm publish` exits non-zero with EPUBLISHCONFLICT (or the modern
// 403/409 wording — npm has changed phrasing several times) when the
// target version already exists. Detect it from stderr so the
// bump-on-conflict loop can react; any other failure rethrows.
function attemptPublish() {
  const r = npmRun(["publish", "--access", "public"], {
    cwd: outDir,
    stdio: ["ignore", "pipe", "pipe"],
  });
  stdout.write(r.stdout || "");
  stderr.write(r.stderr || "");

  if (r.status === 0) return { ok: true };

  const text = (r.stderr || "") + (r.stdout || "");
  if (/EPUBLISHCONFLICT|cannot publish over|previously published versions|version not allowed/i.test(text)) {
    return { ok: false, conflict: true };
  }
  throw new Error(`npm publish failed (no conflict signal):\n${text || r.error?.message}`);
}

const META = "@keton-id/cora";
const MAX_BUMPS = 10; // belt-and-suspenders cap on the conflict loop

let candidate = releaseVersion;
let bumps = 0;

while (true) {
  if (bumps > MAX_BUMPS) {
    fail(`bump-on-conflict loop exceeded ${MAX_BUMPS} iterations — abort`);
  }

  stderr.write(`\n=== candidate ${META}@${candidate} ===\n`);
  const pins = collectPins();
  if (Object.keys(pins).length === 0) {
    fail(`no subpackages published yet — refuse to publish meta with empty optionalDependencies`);
  }

  renderTree(candidate, pins);

  const result = attemptPublish();
  if (result.ok) {
    stderr.write(`published ${META}@${candidate}\n`);
    break;
  }

  // EPUBLISHCONFLICT path: compare pins on the existing version. If
  // identical, this run is idempotent — another release.yml run for
  // the same upstream version already published the same map.
  // Otherwise bump patch and loop; the concurrency group serializes
  // meta jobs so the final survivor sees every sibling subpackage
  // already on the registry, and `latest` lands on the freshest pins.
  stderr.write(`conflict on ${META}@${candidate} — comparing pins\n`);
  const existing = npmViewOptionalDependencies(META, candidate);
  if (pinsEqual(existing, pins)) {
    stderr.write(`${META}@${candidate} already published with identical pins — idempotent exit\n`);
    break;
  }

  const next = bumpPatch(candidate);
  stderr.write(`existing pins differ — bumping ${candidate} -> ${next}\n`);
  candidate = next;
  bumps++;
}
