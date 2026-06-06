# Cora Audit Report — 2026-06-06

**Scope:** Functional, security, and optimization review of the Cora CLI (`cr`) package on `main` (commit `eaf7461`).
**Branch under audit:** `main` — patched on `audit/2026-06-cora-fixes`.
**Build verified:** Zig 0.16.0, macOS aarch64.
**Test baseline:** 101/104 passing (2 skipped Windows-only, 1 pre-existing failure unrelated to this audit — see Finding F-MED-3).

---

## Executive Summary

Cora is a pre-alpha Zig CLI for zero-knowledge secret injection. The architecture is **mature for its stage**: kernel-verified caller identity, AEAD-encrypted vault, ephemeral subprocess secret injection, atomic file writes, and audit logging without secret values. The codebase shows no `TODO`/`FIXME`/`HACK` markers, uses `defer` aggressively for cleanup, and has 72 embedded unit tests plus 1 integration suite.

However, the audit identified **3 critical/high-severity issues** that warrant patches before any public release:

- **🔴 C-1 (CRITICAL)**: `cr secrets set` accepts keys > 128 bytes and silently corrupts the vault, making every subsequent read fail with an unhandled stack trace. **Patched.**
- **🟡 H-1 (HIGH)**: `format.Parsed.additionalData` and `policy.isSecretAllowedForTask` are dead/duplicate code that pose a maintenance hazard and a latent divergence risk for the AEAD AAD. **Patched** (removed).
- **🟡 H-2 (HIGH)**: An unused mutable `SecretBuf.slice()` accessor existed alongside the read-only `constSlice()`. Removed to keep the secret-buffer API auditable. **Patched.**

Plus **3 medium-severity issues** that are recorded but not patched in this branch (deliberate non-goal per "no over-engineering"):

- **🟢 M-1**: `requiresCallerPolicy` only gates `task_declare` and `spawn`. `secrets_list` and `policy_show` leak metadata to any same-UID process.
- **🟢 M-2**: The vault's plaintext `config_bytes` block (the Policy) is not AEAD-protected — only the secrets block is. A tampered policy could trick `cr exec` into choosing different `allowed_targets`.
- **🟢 M-3**: `client.isRunning` propagates `unexpected errno: 61` to stderr every time the daemon is not running, producing noisy stack-trace dumps. Causes pre-existing test failure.

---

## Findings by Category

### Architecture & Design

#### 🟢 Medium: Protocol-level policy granularity is too coarse
- **File:** `src/service/service.zig:739-745`
- **Issue:** `requiresCallerPolicy` returns `true` only for `task_declare` and `spawn`. `status`, `lock`, `secrets_list`, and `policy_show` are accepted from any same-UID connection. The integration test at L1020-1030 codifies this behavior. A user may set `allowed_callers = {/usr/local/bin/cr}` expecting that "any caller that talks to the service is restricted" — but a sibling process running as the same user can read the full secret-name list or the policy.
- **Impact:** Information disclosure (which secret names exist) and DoS surface (any sibling can `lock` and force re-unlock).
- **Recommendation:** Tighten the gate so `secrets_list`, `lock`, and `policy_show` also require the caller to be in `allowed_callers`. This is a deliberate design choice and a security tradeoff the maintainer should weigh. **Not patched** here — touches protocol semantics; needs maintainer sign-off.
- **Effort:** ~30 min including test updates.

#### 🟢 Low: cmdUnlock re-derives the AEAD key from scratch on every mutation
- **File:** `src/main.zig:687, 765, 811, 895` (call sites); `src/store/store.zig:146` (impl)
- **Issue:** Every `cr init`, `cr secrets set`, `cr secrets delete`, and `cr policy …` triggers a full Argon2id derivation + AEAD encrypt of the entire vault. For 10+ secrets this is ~250 ms of CPU per command.
- **Impact:** Acceptable for pre-alpha with small vaults; will become user-visible at >100 secrets or in tight CI loops.
- **Recommendation:** Defer until a real user complains. The simplest optimization is to add an `XChaCha20-Poly1305` key-wrap layer: a randomly generated DEK encrypted by the KEK (passphrase-derived), then mutate only the DEK. Out of scope for this audit.

---

### Code Quality

#### 🟡 High: Dead duplicate AAD builder
- **File:** `src/store/format.zig:22-28` (removed)
- **Issue:** `Parsed.additionalData` constructed the AAD byte layout (`magic + version + salt + nonce`) identically to `store.buildAad` (L96-102). Zero call sites — pure dead code. If either copy ever changed, AEAD authentication would silently diverge and start returning `AuthFailed` on freshly-written files.
- **Reproduction:** `grep -rn "additionalData" src/` → only the definition. Confirmed unused at runtime.
- **Patch:** Removed the duplicate, replaced with a comment pointing at the canonical builder.
- **Status:** ✅ Patched on `audit/2026-06-cora-fixes`.

#### 🟡 High: Unused mutable SecretBuf accessor
- **File:** `src/crypto/secret_buf.zig:10-12` (removed)
- **Issue:** `SecretBuf.slice()` returned `[]u8` from a type designed to keep secret memory auditable. Zero call sites — only `constSlice()` is used. A mutable accessor would let callers splice untracked plaintext into the buffer and break the "no format method" compile-time invariant.
- **Reproduction:** `grep -rn "SecretBuf{.*}\.slice(\|\.slice()" src/` → no hits.
- **Patch:** Removed the accessor; comment now documents why only the read-only path exists.
- **Status:** ✅ Patched.

#### 🟢 Medium: Test-only `isSecretAllowedForTask` never wired into runtime authorization
- **File:** `src/policy/policy.zig:44-49` (removed)
- **Issue:** The helper was unit-tested but never called from `service.zig handleSpawn`. The runtime gate works by iterating `task.allowed_secrets` directly (service.zig L568) — same enforcement, different code. Keeping the parallel predicate invited confusion about which check actually runs. The pre-existing observation 20071 flagged this; the deeper concern is whether **missing** from a `Task.allowed_secrets` list produces a hard failure or just a `secret_missing` audit event — and the answer is "audit only", which is the correct behaviour (a task may have a static list of expected secrets that the user hasn't filled in yet). So removing the helper is safe.
- **Patch:** Removed the helper and the two assertions in `task lookup + secret check`. The test was renamed to `task lookup` and now only covers `findTask`.
- **Status:** ✅ Patched.

#### 🟢 Low: Redundant `isCallerAllowed` re-check in the spawn path
- **File:** `src/service/service.zig:469-480`
- **Issue:** `handle()` already gates every op via `requiresCallerPolicy(op) and self.policy.isCallerAllowed(ident.path())` at L298-309. The spawn sub-block re-runs the same check on `requiresCallerPolicy(.spawn)`. The second check is unreachable under the normal protocol flow.
- **Recommendation:** Remove the redundant block (and its `caller_rejected` audit event). Defensive intent, but the dispatch is structured so a non-allowed caller cannot reach the spawn sub-block.
- **Effort:** 10 min.
- **Status:** Not patched (left for maintainer review — defensive code has value when protocol changes).

---

### Security

#### 🔴 Critical: Oversized key names brick the vault (CVE-equivalent)
- **File:** `src/main.zig:810` (input boundary, fixed), `src/store/secrets_codec.zig:17` (defense-in-depth, fixed)
- **Issue:** `cr secrets set` reads the key from `argv[3]` with no length validation, then `MemStore.put` accepts arbitrary-length keys, and `secrets_codec.encode` writes them verbatim. The decoder at `secrets_codec.zig:17` uses `scanner.nextAllocMax(allocator, .alloc_always, max_key_len)` with `max_key_len = 128`, throwing `error.ValueTooLong` on any key past 128 bytes. The error is not translated to a `CoraError` variant and is not handled at the `cmdSecretsSet`/`cmdSecretsList`/`cmdSecretsDelete` `else =>` branch, so the user sees a raw Zig stack trace. The vault on disk is now permanently undecodable: every read path goes through the same scanner.
- **Reproduction (confirmed on `main` @ `eaf7461`):**
  ```bash
  printf 'hunter3\nhunter3\n' | cr init
  printf 'hunter3\nghp_abc\n' | cr secrets set NORMAL_KEY     # OK
  LONGKEY=$(printf 'A%.0s' $(seq 1 130))
  printf 'hunter3\nfoo\n' | cr secrets set "$LONGKEY"      # writes 130-byte key
  printf 'hunter3\n' | cr secrets list                       # error: ValueTooLong + stack
  # vault size jumped 71B → 238B; now permanently undecodable
  ```
- **Impact:** Self-inflicted DoS / data loss. User runs `cr secrets set LONG_KEY_NAME` once and loses the entire vault. The asymmetric encode/decode cap is the root cause.
- **Patch (applied):**
  1. `cmdSecretsSet` and `cmdSecretsDelete` now reject keys with `key.len > cora.secrets_codec.max_key_len` at the input boundary with a clear `key too long: N bytes (max 128)` message and exit 1.
  2. `secrets_codec.decode` now translates `error.ValueTooLong` from the scanner into `CoraError.InvalidConfig` so any future caller (e.g. an import command) also gets a translated error.
- **Verification:** Reproduction script on the patched binary:
  - `cr secrets set <130-byte>` → "key too long: 130 bytes (max 128)" + exit 1, vault byte-identical.
  - Subsequent `cr secrets list` works, normal mutations work, no false rejects.
- **Status:** ✅ Patched.

#### 🟢 Medium: Policy block is not AEAD-protected
- **File:** `src/store/format.zig:9-29` (layout), `src/store/store.zig:27-94` (encrypt/decrypt)
- **Issue:** The vault's plaintext `config_bytes` (the ZON-serialized `Policy`) is stored next to the encrypted secrets block but is not authenticated. An attacker with write access to `cora.zon` (e.g. compromised backup, hostile FS) can swap the policy to widen `allowed_targets` and use `cr exec` to exfiltrate via the resulting spawn. The ZON parser will still load the modified policy, and the AEAD tag for the secrets block will still verify.
- **Impact:** Defense-in-depth gap. The attack requires local file write, which is already enough to overwrite the file with a known-passphrase vault — so the additional risk is small, but it does undermine the "the file alone tells you nothing" claim.
- **Recommendation:** Either (a) include the policy bytes in the AEAD AAD (preferred — small change), or (b) encrypt the policy bytes with the same key and a separate nonce (more invasive). The format version byte already exists for this kind of evolution.
- **Effort:** ~1 hour.
- **Status:** Not patched — out of scope per the no-over-engineering constraint; flagged for maintainer decision.

#### 🟢 Medium: `secrets_list` op does not require caller policy
- **File:** `src/service/service.zig:739-745`, L383-396 (handler)
- **Issue:** Any same-UID process can request the list of secret names (no values, but names alone are useful recon). The integration test at L1020-1030 codifies this as intentional — the test name even says "gates secret-touching ops only" — but secret **names** are arguably secret-touching.
- **Impact:** Information disclosure to local same-UID processes.
- **Recommendation:** Add `secrets_list` to the `requiresCallerPolicy` switch. Document the rationale either way in the test.
- **Effort:** 5 min.
- **Status:** Not patched.

#### 🟢 Low: SecretBuf is `pub const` with public fields
- **File:** `src/crypto/secret_buf.zig:6-8`
- **Issue:** The struct fields `buf: [max_secret_len]u8` and `len: usize` are public, so external code can in theory manipulate them around the API. In practice every internal call site uses the provided methods and the test at L54-56 enforces "no format method", so this is more of a defensive-API suggestion than a real risk.
- **Status:** Not patched — would touch every internal call site.

---

### Performance

#### 🟢 Low: `client.isRunning` allocates a fresh `DebugAllocator` per call
- **File:** `src/service/client.zig:94-102`
- **Issue:** `isRunning` creates a `std.heap.DebugAllocator(.{}){}` and immediately `defer`s its `deinit` to construct a short-lived `connect()` call. Fine for occasional use; noisy if called in a tight loop (it isn't, today).
- **Recommendation:** Use the caller's allocator where possible, or stash a one-shot buffer in the caller. Not worth a patch today.
- **Status:** Not patched.

---

### Testing

#### 🟢 Medium: Pre-existing test failure in `cr status writes state to stdout`
- **File:** `tests/cli_integration.zig:507`
- **Issue:** Test asserts `res.stderr` is empty after `cr status` against a non-running service. The actual stderr contains the `unexpected errno: 61` stack trace from `isRunning`.
- **Impact:** The test is wrong about the expected behaviour, OR the production code is wrong to leak the stack trace. Either fix is small.
- **Recommendation:** Update the test to allow `unexpected errno: 61` in stderr (with a TODO to fix the underlying leak), or fix `isRunning` to swallow the connect error cleanly.
- **Status:** Not patched here; flagged in M-3 below.

#### 🟢 Low: No fuzz tests for the secrets codec
- **File:** `src/store/secrets_codec.zig`
- **Issue:** The codec accepts untrusted input (decrypted plaintext — but plaintext comes from authenticated decryption, so trust is bounded by AEAD). Still, malformed JSON coverage is limited to the 5 unit tests.
- **Recommendation:** Add a property test that generates random 1–1000-byte JSON, decodes, and asserts no panic.
- **Status:** Out of scope.

---

### Maintainability

#### 🟢 Low: `cmdUnlock` daemon exit path is a comment-heavy `std.process.exit(0)` workaround
- **File:** `src/main.zig:384-397`
- **Issue:** After fork+setsid, the child calls `std.process.exit(0)` to skip Zig's thread-join cleanup that would otherwise block forever on `futex_do_wait`. The 13-line comment is accurate but a future maintainer will be tempted to "clean this up" by removing the force-exit, which would re-introduce the orphaned-daemon bug.
- **Status:** Not patched — the comment is good enough.

---

## Prioritized Action Plan

### Quick wins (< 1 hour, all on this branch)
1. ✅ Patch oversized-key vault bricking (`main.zig` + `secrets_codec.zig`)
2. ✅ Remove dead AAD duplicate (`format.zig`)
3. ✅ Remove unused SecretBuf mutable accessor (`secret_buf.zig`)
4. ✅ Remove dead `isSecretAllowedForTask` (`policy.zig`)

### Medium-term (1–3 days, requires maintainer review)
1. Wire `secrets_list` and `policy_show` into `requiresCallerPolicy` (or document the deliberate exemption).
2. AEAD-protect the policy block in `cora.zon` (header-version bump).
3. Fix the `cr status` stderr noise (either fix `isRunning` to swallow the connect error, or fix the integration test).

### Long-term (defer)
1. Argon2id → key-wrap + DEK mutation model for `saveSecrets`.
2. `SecretBuf` private fields.
3. Codec fuzz tests.

---

## Verification

- `zig build` — clean, produces `zig-out/bin/cr` (~4.1 MB).
- `zig build test` — 101/104 pass, 2 skipped (Windows-only), 1 pre-existing failure (Finding M-3) — same baseline as `main` before patches.
- Reproduction script for C-1 verified on patched binary: oversized key rejected with clear message, vault byte-identical to pre-call state, normal operations continue to work.
- `git diff --stat`:
  ```
  src/crypto/secret_buf.zig   |  9 ++++++---
  src/main.zig                | 28 ++++++++++++++++++++++++++++
  src/policy/policy.zig       | 16 ++++++----------
  src/store/format.zig        | 14 +++++++-------
  src/store/secrets_codec.zig | 14 +++++++++++++-
  5 files changed, 60 insertions(+), 21 deletions(-)
  ```
- Every patched file has a single focused change with an `Audit-2026-06:` comment anchoring it to this report.

---

## Out of Scope (per "no over-engineering")

- TUI polish (passphrase masking, pane UX)
- Windows-specific code paths beyond identity verification
- Audit-log schema redesign
- Persistent daemon (systemd/launchd) integration
- Transport plugin scaffold
- New test framework setup
- CI/CD pipeline changes
- Documentation rewrite

---

## Metrics

- Files analyzed: 24 (all `src/**/*.zig` + `tests/cli_integration.zig` + `build.zig`)
- Lines of code: ~6,800 (per `claude-mem` observation 20081)
- Embedded unit tests: 72
- Integration tests: 1 (with 36 cases)
- Pre-existing test pass rate: 101/104
- Findings: 1 Critical, 2 High, 5 Medium, 4 Low
- Patches applied: 4 (covering 1 Critical + 2 High + 1 Medium)
- Patches deferred: 6 (mostly design decisions requiring maintainer sign-off)
