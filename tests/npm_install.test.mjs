import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { checksumMatches, installPackage, releaseAsset } from "../packaging/npm/meta/bin/install.js";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../packaging/npm/meta");

test("the public npm package is the only package and installs its native binary", () => {
  const manifest = JSON.parse(readFileSync(join(packageRoot, "package.json"), "utf8"));
  assert.equal(manifest.name, "@keton-id/cora");
  assert.equal(manifest.scripts.postinstall, "node bin/install.js");
  assert.equal("optionalDependencies" in manifest, false);
});

test("maps each supported runtime to an asset in the unified release", () => {
  const cases = [
    ["darwin", "x64", "cr-0.12.0-x86_64-macos.tar.gz", "cr"],
    ["darwin", "arm64", "cr-0.12.0-aarch64-macos.tar.gz", "cr"],
    ["linux", "x64", "cr-0.12.0-x86_64-linux.tar.gz", "cr"],
    ["linux", "arm64", "cr-0.12.0-aarch64-linux.tar.gz", "cr"],
    ["win32", "x64", "cr-0.12.0-x86_64-windows.zip", "cr.exe"],
    ["win32", "arm64", "cr-0.12.0-aarch64-windows.zip", "cr.exe"],
  ];

  for (const [platform, arch, archive, executable] of cases) {
    assert.deepEqual(releaseAsset(platform, arch, "0.12.0"), { archive, executable });
  }
  assert.throws(() => releaseAsset("freebsd", "x64", "0.12.0"), /Unsupported Cora platform/);
  assert.throws(() => releaseAsset("linux", "x64", "0.12.0-alpha.1"), /Unsupported Cora release version/);
});

test("requires the downloaded archive to match its SHA256 sidecar", () => {
  const archive = Buffer.from("release archive bytes");
  const digest = createHash("sha256").update(archive).digest("hex");
  assert.equal(checksumMatches(archive, `${digest}  archive.tar.gz\n`), true);
  assert.equal(checksumMatches(archive, `${"0".repeat(64)}  archive.tar.gz\n`), false);
  assert.equal(checksumMatches(archive, "not-a-digest"), false);
});

test("postinstall downloads, checks, and installs one host binary", async (t) => {
  const root = mkdtempSync(join(tmpdir(), "cora-npm-test-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const version = "0.12.0";
  writeFileSync(join(root, "package.json"), JSON.stringify({ name: "@keton-id/cora", version }));

  const { archive, executable } = releaseAsset(process.platform, process.arch, version);
  const payload = join(root, "payload");
  const archivePath = join(root, archive);
  mkdirSync(payload);
  writeFileSync(join(payload, executable), "test native binary\n");

  if (process.platform === "win32") {
    const psQuote = (value) => `'${value.replaceAll("'", "''")}'`;
    execFileSync("powershell.exe", [
      "-NoProfile",
      "-NonInteractive",
      "-Command",
      `Compress-Archive -LiteralPath ${psQuote(join(payload, executable))} -DestinationPath ${psQuote(archivePath)} -Force`,
    ]);
  } else {
    execFileSync("tar", ["-czf", archivePath, "-C", payload, executable]);
  }

  const archiveBytes = readFileSync(archivePath);
  const digest = createHash("sha256").update(archiveBytes).digest("hex");
  const seen = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    seen.push(String(url));
    return new Response(String(url).endsWith(".sha256") ? `${digest}\n` : archiveBytes);
  };
  try {
    await installPackage(root);
  } finally {
    globalThis.fetch = originalFetch;
  }

  const installed = join(root, "bin", "native", executable);
  assert.equal(existsSync(installed), true);
  assert.equal(seen.length, 2);
  assert.ok(seen.every((url) => url.includes(`/v${version}/`)));
});
