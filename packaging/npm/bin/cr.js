#!/usr/bin/env node
// Thin launcher for the @keton-id/cora npm package. Picks the right
// pre-built native cr binary out of vendor/ based on process.platform
// and process.arch, then execs it with the caller's argv and stdio.
//
// No network calls at runtime or install time. All binaries are bundled
// into the npm tarball at publish time, with sha256 verification
// performed in CI against the matching GitHub Release.

import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { existsSync } from "node:fs";

const here = dirname(fileURLToPath(import.meta.url));
const key = `${process.platform}-${process.arch}`;
const exeName = process.platform === "win32" ? "cr.exe" : "cr";
const binPath = join(here, "..", "vendor", key, exeName);

if (!existsSync(binPath)) {
  process.stderr.write(
    `cr: no prebuilt binary for ${key}.\n` +
      `Supported: darwin-x64, darwin-arm64, linux-x64, linux-arm64, win32-x64, win32-arm64.\n` +
      `Reinstall, or build from source: https://github.com/keton-id/cora\n`,
  );
  process.exit(1);
}

const result = spawnSync(binPath, process.argv.slice(2), { stdio: "inherit" });

if (result.error) {
  process.stderr.write(`cr: failed to spawn ${binPath}: ${result.error.message}\n`);
  process.exit(1);
}
if (result.signal) {
  // Re-raise via non-zero exit. Mirroring the child's signal exactly
  // would require process.kill on self, which has surprising semantics
  // under Node on Windows; a generic 1 is more portable.
  process.exit(1);
}
process.exit(result.status ?? 0);
