#!/usr/bin/env node
import { argv, exit, stderr } from "node:process";
import { cpSync, copyFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

function fail(message) {
  stderr.write(`prepare-package: ${message}\n`);
  exit(1);
}

function arg(name) {
  const index = argv.indexOf(`--${name}`);
  if (index < 0 || index === argv.length - 1) fail(`missing --${name}`);
  return argv[index + 1];
}

const version = arg("version");
const sourceDir = resolve(arg("src"));
const outputDir = resolve(arg("out"));
const licensePath = resolve(arg("license"));

if (!/^\d+\.\d+\.\d+$/.test(version)) {
  fail(`--version must be stable semver (got: ${version})`);
}

rmSync(outputDir, { recursive: true, force: true });
mkdirSync(outputDir, { recursive: true });
cpSync(sourceDir, outputDir, { recursive: true });

const manifestPath = join(outputDir, "package.json");
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
if (manifest.name !== "@keton-id/cora" || "optionalDependencies" in manifest) {
  fail("package template must publish only @keton-id/cora with no platform packages");
}
manifest.version = version;
writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
copyFileSync(licensePath, join(outputDir, "LICENSE"));
stderr.write(`prepared @keton-id/cora@${version} at ${outputDir}\n`);
