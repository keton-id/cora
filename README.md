# cora 🤫

[![CI](https://github.com/keton-id/cora/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/keton-id/cora/actions/workflows/ci.yml)
[![License: AGPL-3.0-only](https://img.shields.io/badge/License-AGPL--3.0--only-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/keton-id/cora/pulls)

> *"He never let anyone hear his true voice."*

**Zero-knowledge secret injection for AI agents. Written in Zig.**

Your agent never holds secret values. Not in memory. Not on disk. Not ever.
One encrypted file. One passphrase. Carry it anywhere.

---

## The Problem

Every AI agent runtime today has the same flaw:

```bash
ANTHROPIC_API_KEY=sk-ant-... claude -p "summarize this repo"
```

Your agent now has `sk-ant-...` in its environment. Every skill can read it.
Every prompt injection can ask for it. Every malicious plugin can exfiltrate it.

---

## The Fix

```bash
cr unlock                                       # enter passphrase — service starts
cr exec claude-task -- claude -p "summarize this repo"
```

Claude spawns. It needs `ANTHROPIC_API_KEY`. The Cora service injects it
directly into the subprocess environment after verifying the caller binary
at the **kernel level**.

The `cr` client process never reads the value. The Claude subprocess uses it
and exits. Memory zeroed.

Prompt injection tries `"print ANTHROPIC_API_KEY"` against the orchestrating
agent — nothing to print. The value was never in that process.

---

## Install

Pick whichever fits your trust model — click to expand.

<details>
<summary><strong>A. Pre-built binary via install script</strong> &nbsp;<em>(recommended)</em></summary>

```bash
curl -fsSL https://raw.githubusercontent.com/keton-id/cora/main/install.sh | sh
```

Fetches the latest stable release for your OS/arch, verifies the SHA256
checksum, and installs to `/usr/local/bin` (or `~/.local/bin` without sudo).

Flags:

```bash
# Pin a specific tag
curl -fsSL https://raw.githubusercontent.com/keton-id/cora/main/install.sh \
    | sh -s -- --version {{VERSION}}

# Track a prerelease channel
curl -fsSL https://raw.githubusercontent.com/keton-id/cora/main/install.sh \
    | sh -s -- --channel alpha
```

</details>

<details>
<summary><strong>B. Homebrew</strong> &nbsp;<code>brew install cora</code> &nbsp;<em>(macOS + Linux)</em></summary>

```bash
brew tap keton-id/tap
brew install cora
```

The package name is `cora`; the installed binary is `cr`. `brew upgrade cora`
picks up new stable releases. The
[`keton-id/homebrew-tap`](https://github.com/keton-id/homebrew-tap) repo
is updated automatically by Cora's release pipeline on every stable
tag. Pre-release alpha tags are **not** pushed to the tap.

</details>

<details>
<summary><strong>C. Scoop</strong> &nbsp;<code>scoop install cora</code> &nbsp;<em>(Windows)</em></summary>

```powershell
scoop bucket add keton-id https://github.com/keton-id/scoop-bucket
scoop install cora
```

The package name is `cora`; the installed binary is `cr.exe`. `scoop update cora`
picks up new stable releases. The
[`keton-id/scoop-bucket`](https://github.com/keton-id/scoop-bucket) repo
is updated automatically on every stable tag.

</details>

<details>
<summary><strong>D. npm</strong> &nbsp;<code>npm i -g @keton-id/cora</code></summary>

```bash
npm i -g @keton-id/cora
```

Or one-shot via `npx`:

```bash
npx @keton-id/cora --help
```

Ships a single npm package that bundles prebuilt `cr` binaries for
every supported platform — macOS x64/arm64, Linux x64/arm64, Windows
x64/arm64. A tiny JS launcher (`bin/cr.js`) picks the matching binary
at runtime. No postinstall download, no native node addon. Only
stable releases publish to npm; alphas stay on GitHub Releases.

</details>

<details>
<summary><strong>E. Manual download from GitHub Releases</strong></summary>

Grab the archive for your platform from the
[Releases page](https://github.com/keton-id/cora/releases) and verify
the checksum yourself.

POSIX (tarball):

```bash
VERSION=1.0.0
TARGET=aarch64-macos        # or x86_64-macos / x86_64-linux / aarch64-linux
curl -fsSLO "https://github.com/keton-id/cora/releases/download/v${VERSION}/cr-${VERSION}-${TARGET}.tar.gz"
curl -fsSLO "https://github.com/keton-id/cora/releases/download/v${VERSION}/cr-${VERSION}-${TARGET}.tar.gz.sha256"
shasum -a 256 -c <(echo "$(cat cr-${VERSION}-${TARGET}.tar.gz.sha256)  cr-${VERSION}-${TARGET}.tar.gz")
tar xzf "cr-${VERSION}-${TARGET}.tar.gz"
sudo install -m 0755 cr /usr/local/bin/
```

Windows (zip):

```powershell
$VERSION = "1.0.0"
$TARGET  = "x86_64-windows"   # or aarch64-windows
Invoke-WebRequest "https://github.com/keton-id/cora/releases/download/v$VERSION/cr-$VERSION-$TARGET.zip" -OutFile cr.zip
Expand-Archive cr.zip -DestinationPath $Env:LOCALAPPDATA\cora\bin
$Env:PATH += ";$Env:LOCALAPPDATA\cora\bin"
cr version
```

</details>

<details>
<summary><strong>F. Build from source</strong> &nbsp;<em>(Zig 0.16+)</em></summary>

```bash
git clone https://github.com/keton-id/cora && cd cora
```

Native Zig workflow:

```bash
zig build -Doptimize=ReleaseSafe
sudo install -m 0755 zig-out/bin/cr /usr/local/bin/cr
```

Convenience wrapper via `make`:

```bash
make release
make install                      # installs to ~/.local/bin by default
```

Install to another prefix:

```bash
make install PREFIX=/usr/local
```

</details>

---

## Quick Start (with Claude Code)

```bash
# First-time setup
cr init                                   # passphrase prompt + confirm
cr secrets set ANTHROPIC_API_KEY          # paste real key
cr policy allow $(which cr)               # cr itself is the IPC client
cr policy allow $(which claude)           # the agent we'll spawn
cr policy task add claude-task ANTHROPIC_API_KEY

# Use it
cr unlock                                 # decrypt + start background service
cr exec claude-task -- claude -p "say hi"
cr audit tail                             # see what happened
cr lock                                   # zero memory, stop service
```

The `claude` subprocess sees `$ANTHROPIC_API_KEY`. The orchestrating `cr exec`
process only gets back `child pid <N> exit <code>`.

Verify by grepping for the value in any state Cora touches:

```bash
grep -a 'sk-ant-' cora.zon               # → no hits (encrypted)
grep -a 'sk-ant-' ~/.cora/audit.jsonl    # → no hits (names only)
```

---

## How It Works

```
cora.zon (always encrypted on disk — XChaCha20-Poly1305)
    ↓ cr unlock (Argon2id passphrase → key → decrypt → key zeroed)
Service memory (secrets live here while unlocked)
    ↓ cr exec
Subprocess env (secret injected directly, agent never touches it)
    ↓ task done
secureZero — temporary copy zeroed immediately
    ↓ cr lock
All memory zeroed. Back to encrypted at rest.
```

---

## Portable

`cora.zon` is one file. Take it to any machine, container, or CI/CD environment.
No OS keychain dependency. No cloud. No sync service.

```bash
scp cora.zon user@server:~/
# cr unlock on server — same passphrase, same secrets
```

---

## What's Inside

| Feature                | Command                                  |
| ---------------------- | ---------------------------------------- |
| Encrypted file at rest | `cr init`                                |
| Manage secrets         | `cr secrets set\|list\|delete`           |
| Caller allowlist       | `cr policy allow\|deny PATH`             |
| Task scoping           | `cr policy task add NAME SECRETS...`     |
| Service lifecycle      | `cr unlock` / `cr lock` / `cr status`    |
| Spawn agent            | `cr exec TASK -- argv...`                |
| Audit trail            | `cr audit tail` / `cr audit show`        |
| Interactive menu       | `cr tui`                                 |
| Identity debug         | `cr verify --pid PID`                    |

Run `cr` with no args for full usage.

---

## How It's Different

|                   | cora                | .env files | Vault   |
| ----------------- | ------------------- | ---------- | ------- |
| Storage           | **Encrypted file**  | Plaintext  | Cloud   |
| Portable          | **Yes — one file**  | Partial    | No      |
| Memory zeroing    | **`secureZero`**    | GC         | N/A     |
| Caller verified   | **OS kernel**       | Nothing    | Nothing |
| Agent gets value? | **Never**           | Yes        | Depends |
| Infra required    | **None**            | None       | Heavy   |
| Single binary     | **Yes**             | N/A        | No      |
| Interactive TUI   | **Yes (pane-based)** | No         | No      |

---

## License

AGPL-3.0 — free to use, modify, and distribute.
If you build on Cora, your code stays open too.

---

## Security

Read [SECURITY.md](SECURITY.md) for the threat model, known residuals, and
responsible disclosure (via GitHub Security Advisories).

---

*Named after Donquixote Rosinante(Corazon) — who hid everything to protect what mattered.*
