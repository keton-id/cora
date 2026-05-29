# Security Policy

Cora is a secret-handling runtime. Security is its only feature. This document
describes what we guarantee, what we do not, how to report vulnerabilities, and
where to look for known residual risk.

---

## Supported Versions

Cora is pre-alpha. Only the latest `main` branch (`0.x` HEAD) is supported.
No LTS line exists yet.

| Version       | Supported          |
| ------------- | ------------------ |
| `0.x` (HEAD)  | ✅ active           |
| `< 0.x`       | n/a (no releases)  |

A tagged release line will start at `v0.1.0` with a documented support window.

---

## Reporting a Vulnerability

**Do not open public GitHub issues for security vulnerabilities.**

Report via **GitHub Security Advisories** (private channel):

> https://github.com/<your-fork>/cora/security/advisories/new

This creates a private, repo-scoped report that maintainers can triage and
patch before public disclosure.

### Response SLA

- **7 days** — initial acknowledgment.
- **30 days** — patched build or mitigation in `main`, when feasible.
- **90 days** — coordinated public disclosure window (or sooner if the vuln
  is already being exploited in the wild).

If you do not get an acknowledgment within 7 days, the report may have been
missed — escalate by opening a private contact issue tagged `triage`.

---

## Scope

### In-scope vulnerabilities

- Disclosure of decrypted secret material from Cora's process memory
  (heap dump while service is locked, residue in swap, etc.)
- Bypass of caller identity verification (e.g. spoofed `SO_PEERCRED`,
  TOCTOU between identity check and op handling)
- Crypto downgrade or weakened parameters (Argon2id, XChaCha20-Poly1305)
- Authentication-tag forgery / accepted ciphertext tampering
- Allowlist bypass — a non-allowed binary getting past `identity.verify`
- Audit log emitting any secret value field
- Plaintext write of the secrets block to disk under any code path
- IPC parsing bugs that allow arbitrary memory read/write

### Out-of-scope

- User chose a weak passphrase (Cora warns; can't enforce).
- Attacker already has root or same-UID as the user (game over by design).
- Physical access (cold boot, hardware keylogger, evil maid).
- Social engineering of the human passphrase holder.
- An allowed agent process misusing a correctly-injected secret
  (Cora can't audit what the subprocess does with `$ANTHROPIC_API_KEY`).
- Compromised Zig compiler or supply chain (track upstream).
- Bugs in `vaxis` or other dependencies — report upstream, then notify here
  if a Cora-specific mitigation is needed.

---

## Cryptographic Primitives

All from `std.crypto` — no external crypto deps.

| Primitive              | Parameters / Sizes                                 |
| ---------------------- | -------------------------------------------------- |
| Key derivation         | Argon2id `t=3, m=65536 (64 MiB), p=4`              |
| Authenticated cipher   | XChaCha20-Poly1305                                 |
| Salt                   | 16 bytes random per `cr init`                      |
| Nonce                  | 24 bytes random per encryption (every secrets write) |
| Derived key            | 32 bytes — zeroed via `std.crypto.secureZero` after each decrypt |
| Auth tag (Poly1305)    | 16 bytes                                           |
| Additional data (AAD)  | magic `"CORA"` + version byte + salt + nonce       |

The derived key never persists beyond the ~1–2 seconds needed to decrypt or
re-encrypt the secrets block. The plaintext secrets live in heap-allocated
`SecretBuf` instances only while the service is running.

---

## Core Guarantee

An agent process **never holds a secret value in its memory**.

- `cora.zon` is always encrypted on disk.
- Secrets are decrypted into service memory only after passphrase unlock.
- The injection API (`spawn`) places values into a freshly-spawned
  subprocess's environment block — the values are never returned to the
  IPC caller. The caller only receives `child_pid` and `exit_code`.
- Per-spawn temporary `SecretBuf` copies are zeroed via `std.crypto.secureZero`
  on `defer`.
- On `cr lock`, idle timeout, or process exit, the full `MemStore` is iterated
  and every `SecretBuf` is zeroed.

---

## Defense Layers

| Attack                                            | Layer that stops it                                       |
| ------------------------------------------------- | --------------------------------------------------------- |
| Read `cora.zon` from disk                         | XChaCha20-Poly1305 + Argon2id (memory-hard brute force)   |
| Tamper with `cora.zon`                            | Poly1305 auth tag fails decrypt                           |
| Prompt-inject the orchestrating agent             | Agent never held the value; no API to retrieve it back    |
| Malicious skill reads filesystem                  | No plaintext secret file exists                           |
| Unknown process connects to UDS                   | `chmod 600` socket + kernel-verified caller binary path   |
| Replay an old `cora.zon` backup                   | Fresh nonce per write; old backup = old secrets (expected) |
| Service crash leaks memory                        | `defer` runs on stack unwind; OS reclaims process pages   |
| Wrong passphrase                                  | Auth tag fails before any plaintext returned              |

---

## Security Guarantees by Platform

Cora ships on Linux, macOS, and Windows, but the security model is **not**
identical on all three. Linux is the reference platform: every guarantee is
enforced by code at runtime. macOS is close but trusts the filesystem
permission of the socket for part of the caller-identity check. Windows is
explicitly a **Tier-1 preview**: AF_UNIX on Windows does not expose peer
process credentials, so Cora cannot do kernel-level caller verification there
and falls back to the user-only NTFS ACL inherited from `%LOCALAPPDATA%`.

| Property                                  | Linux                             | macOS                             | Windows (preview)                          |
| ----------------------------------------- | --------------------------------- | --------------------------------- | ------------------------------------------ |
| Encrypted-at-rest secrets block           | ✅ XChaCha20-Poly1305 + Argon2id  | ✅ XChaCha20-Poly1305 + Argon2id  | ✅ XChaCha20-Poly1305 + Argon2id           |
| Atomic rewrite of `cora.zon`              | ✅ `rename(2)` replace            | ✅ `rename(2)` replace            | ✅ `NtSetInformationFile` `REPLACE_IF_EXISTS` |
| Caller binary verified by OS              | ✅ `SO_PEERCRED` + `/proc/<pid>/exe` | ⚠️ `LOCAL_PEERPID` + `proc_pidpath` (PID-only) | ❌ No peer PID via AF_UNIX — Tier 2 = Named Pipes |
| Socket permission boundary                | ✅ `chmod 0600` on bind           | ✅ `chmod 0600` on bind           | ⚠️ Inherited NTFS ACL from `%LOCALAPPDATA%\cora` |
| Socket parent location verified           | n/a (`/tmp`)                      | n/a (`/tmp`)                      | ✅ Service refuses to start if path escapes `%LOCALAPPDATA%\cora` |
| Secret prompt echo masking                | ✅ `termios` `ECHO` off            | ✅ `termios` `ECHO` off            | ✅ `SetConsoleMode` strips `ENABLE_ECHO_INPUT`, fails closed |
| Service runs in background by default     | ✅ `fork` + `setsid`              | ✅ `fork` + `setsid`              | ❌ Foreground only (`cr unlock`)            |
| Audit log emits preview notice on start   | n/a                               | n/a                               | ✅ `windows_preview_mode` event             |

**Reading this table:**

- ✅ — enforced by Cora code or a primitive that meets the guarantee.
- ⚠️ — partial / depends on OS-level assumption that Cora does not itself enforce.
- ❌ — not provided at this tier; documented as a Known Residual and tracked
  on the Hardening Roadmap.

Operators running Cora on Windows should treat it as `preview`-grade: file
encryption and atomic rewrite are real, but the *who-is-calling* answer falls
back to "whoever has access to the socket file under your user profile",
**not** "the kernel says PID *N* is binary *X*". Move to Linux/macOS where the
guarantee is needed.

---

## Known Residuals

Documented gaps in the current implementation. Each is an open issue;
contributions welcome.

- **macOS LOCAL_PEERPID TOCTOU.** PID returned by `getsockopt(LOCAL_PEERPID)` could in principle be reused between identity check and op handling. Audit-token-based verification (per macOS spec) is on the roadmap.
- **Windows is a Tier-1 preview.** AF_UNIX on Windows does not expose peer process credentials, so caller identity falls back to the user-only NTFS ACL inherited from `%LOCALAPPDATA%\cora`. Service refuses to start if the socket path escapes that prefix. Tier 2 — Named Pipes + `GetNamedPipeClientProcessId` — is on the Hardening Roadmap. See the platform-guarantees table above.
- **Idle timer clock.** Uses `Io.Timestamp.now(io, .awake)` — system suspend may not count toward idle time on all platforms, extending real-world idle beyond the configured value.
- **Audit log rotation.** None. Truncate `~/.cora/audit.jsonl` manually if it grows. Log rotation is planned post-v0.1.
- **No daemon supervision.** If the background service crashes you re-run `cr unlock`. No systemd/launchd contrib files ship with the project — community contributions welcome.
- **TUI polish.** `cr tui` is a minimal ANSI menu; richer vaxis widgets (scrollable audit, full-screen onboarding) are still deferred. Secret prompt echo masking itself is already enforced on every supported platform: `termios` `ECHO` off on POSIX, `SetConsoleMode` strip of `ENABLE_ECHO_INPUT` on Windows.

---

## What Cora Does NOT Protect Against

- Weak passphrase — user responsibility.
- Compromised OS kernel — Cora is userspace.
- Physical access — cold boot, hardware keylogger.
- Unlocked service + root attacker — memory dump possible at that level.
- User misconfiguring `allowed_callers` — Cora trusts its own decrypted policy.
- Secrets stored outside Cora — `.env` files etc. are not Cora's concern.
- Agent misusing a correctly-injected secret (sending it to an unintended endpoint).

---

## Why Not MCP

If Cora were an MCP server, an agent could call `get_secret("ANTHROPIC_API_KEY")`
and receive the value back into agent context — destroying the core guarantee.

MCP is explicitly a non-goal. PRs adding MCP support will be closed.

---

## AGPL-3.0 Warranty Disclaimer

Cora is distributed under the GNU Affero General Public License v3.0.
Per §§ 15 and 16 of the license:

> **15. Disclaimer of Warranty.**
> THERE IS NO WARRANTY FOR THE PROGRAM, TO THE EXTENT PERMITTED BY APPLICABLE LAW.
> EXCEPT WHEN OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
> PROVIDE THE PROGRAM "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR
> IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
> AND FITNESS FOR A PARTICULAR PURPOSE. THE ENTIRE RISK AS TO THE QUALITY AND
> PERFORMANCE OF THE PROGRAM IS WITH YOU. SHOULD THE PROGRAM PROVE DEFECTIVE, YOU
> ASSUME THE COST OF ALL NECESSARY SERVICING, REPAIR OR CORRECTION.
>
> **16. Limitation of Liability.**
> IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING WILL ANY
> COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MODIFIES AND/OR CONVEYS THE PROGRAM AS
> PERMITTED ABOVE, BE LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL,
> INCIDENTAL OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
> THE PROGRAM …

Cora is provided **AS-IS** with **NO WARRANTY**. Security review and audit are
community responsibilities under the copyleft model. Production use is at your
own risk; we recommend you treat Cora as you would any pre-1.0 cryptographic
software — review the source, test in your environment, file private security
reports for anything you find.

See [`LICENSE`](LICENSE) for the full AGPL-3.0 text.

---

## Security Checklist for Contributors

Before opening a PR that touches secret-handling code, confirm:

- [ ] `defer secret.zero()` is the first line after any `SecretBuf` init?
- [ ] `defer std.crypto.secureZero(u8, &key)` after any key derivation buffer?
- [ ] `SecretBuf` still has no `format` method — compile error if logged?
- [ ] `cora.zon` secrets block always encrypted before write?
- [ ] Passphrase never stored — only used to derive key, then zeroed?
- [ ] No `value` / `secret_value` field added to any `audit.Event` variant?
- [ ] New code handles all error paths — does `defer` still fire on `try` failure?
- [ ] Platform identity code reviewed for TOCTOU between check and use?
- [ ] No new dependency that pulls plaintext secrets through its API surface?
- [ ] `zig build test` passes (51/51 baseline)?

---

## Hardening Roadmap (post-v0.1)

These are tracked but not yet implemented:

- macOS audit-token caller identity (replace LOCAL_PEERPID).
- Windows Named Pipe + `GetNamedPipeClientProcessId` support (Tier 2 — replaces the AF_UNIX preview).
- Log rotation by size + age.
- Optional `mlock(2)` of `SecretBuf` heap pages to prevent swap.
- Reproducible release builds + signed binaries.

Contributions for any of the above are welcome via standard PRs (not the
security channel).
