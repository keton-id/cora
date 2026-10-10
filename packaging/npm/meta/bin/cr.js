#!/usr/bin/env node
// Launch the native binary fetched by the package's postinstall step.

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const platform = process.platform;
const arch = process.arch;
const exeName = platform === "win32" ? "cr.exe" : "cr";
const binPath = join(dirname(fileURLToPath(import.meta.url)), "native", exeName);

if (!existsSync(binPath)) {
  process.stderr.write(
    `cr: native binary missing for ${platform}-${arch}; npm postinstall may have failed. ` +
      "Reinstall the package or run `npm rebuild @keton-id/cora`.\n",
  );
  process.exit(1);
}

const result = spawnSync(binPath, process.argv.slice(2), { stdio: "inherit" });
if (result.error) {
  process.stderr.write(`cr: failed to spawn ${binPath}: ${result.error.message}\n`);
  process.exit(1);
}
if (result.signal) process.exit(1);
process.exit(result.status ?? 0);
