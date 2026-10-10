#!/usr/bin/env node
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const releaseBase = "https://github.com/keton-id/cora/releases/download";
const targets = {
  "darwin:x64": "x86_64-macos",
  "darwin:arm64": "aarch64-macos",
  "linux:x64": "x86_64-linux",
  "linux:arm64": "aarch64-linux",
  "win32:x64": "x86_64-windows",
  "win32:arm64": "aarch64-windows",
};

export function releaseAsset(platform, arch, version) {
  if (!/^\d+\.\d+\.\d+$/.test(version)) {
    throw new Error(`Unsupported Cora release version: ${version}`);
  }
  const target = targets[`${platform}:${arch}`];
  if (!target) throw new Error(`Unsupported Cora platform: ${platform}/${arch}`);
  const windows = platform === "win32";
  return {
    archive: `cr-${version}-${target}.${windows ? "zip" : "tar.gz"}`,
    executable: windows ? "cr.exe" : "cr",
  };
}

export function checksumMatches(archive, sidecar) {
  const expected = sidecar.trim().split(/\s+/)[0]?.toLowerCase();
  if (!expected || !/^[a-f0-9]{64}$/.test(expected)) return false;
  return createHash("sha256").update(archive).digest("hex") === expected;
}

async function download(url) {
  const response = await fetch(url, {
    headers: { "user-agent": "cora-npm-installer" },
  });
  if (!response.ok) throw new Error(`Download failed (${response.status}): ${url}`);
  return Buffer.from(await response.arrayBuffer());
}

function powershellLiteral(value) {
  return `'${value.replaceAll("'", "''")}'`;
}

export async function installPackage(root = packageRoot) {
  const manifest = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
  const { archive, executable } = releaseAsset(process.platform, process.arch, manifest.version);
  const baseUrl = `${releaseBase}/v${manifest.version}`;
  const [archiveBytes, sidecarBytes] = await Promise.all([
    download(`${baseUrl}/${archive}`),
    download(`${baseUrl}/${archive}.sha256`),
  ]);
  if (!checksumMatches(archiveBytes, sidecarBytes.toString("utf8"))) {
    throw new Error(`SHA256 verification failed for ${archive}`);
  }

  const tempDir = mkdtempSync(join(tmpdir(), `cora-${process.pid}-`));
  try {
    const archivePath = join(tempDir, archive);
    const extractDir = join(tempDir, "extract");
    writeFileSync(archivePath, archiveBytes, { flag: "wx" });
    mkdirSync(extractDir);

    if (process.platform === "win32") {
      execFileSync("powershell.exe", [
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        `Expand-Archive -LiteralPath ${powershellLiteral(archivePath)} -DestinationPath ${powershellLiteral(extractDir)} -Force`,
      ], { stdio: "inherit" });
    } else {
      execFileSync("tar", ["-xzf", archivePath, "-C", extractDir, executable], { stdio: "inherit" });
    }

    const extracted = join(extractDir, executable);
    if (!existsSync(extracted)) throw new Error(`Release archive is missing ${executable}`);

    const nativeDir = join(root, "bin", "native");
    mkdirSync(nativeDir, { recursive: true });
    const destination = join(nativeDir, executable);
    const staged = `${destination}.tmp-${process.pid}`;
    copyFileSync(extracted, staged);
    if (process.platform !== "win32") chmodSync(staged, 0o755);
    renameSync(staged, destination);
    console.log(`Installed Cora ${manifest.version} for ${process.platform}/${process.arch}`);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  installPackage().catch((error) => {
    console.error(`@keton-id/cora install failed: ${error.message}`);
    process.exitCode = 1;
  });
}
