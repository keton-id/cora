#!/usr/bin/env node
// Thin launcher for the @keton-id/cora meta npm package. Resolves the
// matching @keton-id/cora-<platform>-<arch> optionalDependency at runtime
// and execs its bundled native cr binary with the caller's argv and stdio.
//
// Subpackages are pulled in by npm at install time via optionalDependencies;
// `os` and `cpu` fields on each subpackage cause npm to silently skip the
// six that don't match the host. No postinstall, no network, no vendor/.

import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

const platform = process.platform;
const arch = process.arch;
const subpackage = `@keton-id/cora-${platform}-${arch}`;
const exeName = platform === "win32" ? "cr.exe" : "cr";

let binPath;
try {
  // Subpackages publish `package.json` at the root; resolve it then
  // join `bin/<exe>` so we don't need a JS shim in the subpackage.
  const pkgPath = require.resolve(`${subpackage}/package.json`);
  const { dirname, join } = await import("node:path");
  binPath = join(dirname(pkgPath), "bin", exeName);
} catch {
  process.stderr.write(
    `cr: no prebuilt binary for ${platform}-${arch}.\n` +
      `Supported: darwin-x64, darwin-arm64, linux-x64, linux-arm64, win32-x64, win32-arm64.\n` +
      `npm should have installed ${subpackage} as an optionalDependency — try reinstalling, or build from source: https://github.com/keton-id/cora\n`,
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
