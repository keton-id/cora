# CLAUDE.md — Cora Project Context

> "He never let anyone hear his true voice."
> Corazon hid everything to protect what mattered. This tool does the same for your secrets.

---

## What is Cora?

Cora is a **zero-knowledge secret injection runtime** for AI agents, written in Zig.

The core guarantee: **an agent never holds a secret value. Ever.**

It only holds names. Cora holds the values — decrypted in memory only while the background service is running, injected directly into subprocess scope, then zeroed.

This is not a secret manager. This is not a vault. This is not a proxy.
This is an **encrypted-file-based, agent-aware, ephemeral credential whisperer.**

CLI command: `cr`
License: AGPL-3.0
Status: pre-alpha · macOS + Linux + Windows (Tier 1) · Zig 0.16

---

## Why This Exists

Current state of the ecosystem:

- **HashiCorp Vault** — enterprise, heavy infra, not agent-aware, not portable
- **direnv / .env files** — plaintext, agent reads everything always
- **OS keychains** — not portable across machines, different API per OS

Cora's differentiators:
1. **Portable** — one encrypted `cora.zon` file, carry it anywhere: laptop, server, CI/CD, container
2. **Passphrase-derived encryption** — Argon2id → XChaCha20-Poly1305, human holds the key
3. **Service model** — `cr unlock` decrypts into memory, background service serves secrets, `cr lock` zeroes everything
4. **Caller identity verified at kernel level** — `SO_PEERCRED` (Linux), `LOCAL_PEERPID` (macOS), `GetNamedPipeClientProcessId` (Windows)
5. **Agent never holds values** — only names, injection goes directly into subprocess env
6. **Zero infra** — single binary, no cloud, no daemon unless user wants one via systemd/launchd
7. **Transport plugins** — OS keychain, 1Password, Vault, Infisical etc. are future community plugins, not core

---

## Core Concepts

### Encryption Model

```
cora.zon (at rest)
  └── secrets block: encrypted with XChaCha20-Poly1305
        └── key derived from: Argon2id(passphrase + salt)
        └── salt: stored in plaintext in cora.zon header
        └── nonce: stored alongside ciphertext

cr unlock
  └── user enters passphrase
  └── Argon2id derives key (memory-hard, slow by design)
  └── XChaCha20-Poly1305 decrypts secrets block
  └── plaintext lives ONLY in service memory
  └── cora.zon on disk: always encrypted

cr lock / idle timeout / process exit
  └── std.crypto.secureZero zeros all secret buffers
  └── service exits
  └── nothing sensitive remains anywhere
```

Crypto params (live in `src/crypto/derive.zig` + `src/crypto/aead.zig`):
- Argon2id `t=3, m=65536 (64MB), p=4`, salt 16B, key 32B
- XChaCha20-Poly1305 nonce 24B, tag 16B
- AAD binds ciphertext to file header (magic + version + salt + nonce)

### The Whisperer Model

```
Agent process              Cora Service               cora.zon (disk)
     |                          |                          |
     |  "I need GITHUB_TOKEN"   |                          |
     |  (name only, via UDS)    |                     [encrypted]
     | -----------------------> |                          |
     |                          | verify caller identity   |
     |                          | check task scope policy  |
     |                          | fetch from memory        |
     |                          | (already decrypted)      |
     |                          |                          |
     |                          | inject into subprocess   |
     |                          | secureZero after spawn   |
     |                          |                          |
     | <-- subprocess spawned   |                          |
     |     agent never sees val |                          |
     |                          |                          |
     | task done                |                          |
     | -----------------------> |                          |
     |                          | memory zeroed            |
```

### Service Lifecycle

```
cr unlock
  → passphrase prompt (masked: termios on POSIX, SetConsoleMode fail-closed on Windows)
  → Argon2id derive key
  → decrypt cora.zon secrets block into memory
  → fork + setsid + dup2 stdio→/dev/null
  → listen on UDS at /tmp/cora-<uid>.sock
  → idle timer starts (configurable, default 15min)

[service running]
  → cr / cr secrets / cr audit / cr exec all talk to service via UDS
  → each request resets idle timer

cr lock  OR  idle timeout  OR  process exit
  → iterate MemStore → SecretBuf.zero() each (secureZero under the hood)
  → unlink socket
  → service exits
  → disk state unchanged (still encrypted)

# Persistent daemon (systemd/launchd) deferred — community contribution.
```

### Caller Identity

Cora does not trust application-level tokens. It trusts the OS.

| Platform | Mechanism                                      | What's Verified                            |
| -------- | ---------------------------------------------- | ------------------------------------------ |
| Linux    | `SO_PEERCRED` via `getsockopt`                 | PID, UID, GID — kernel-provided            |
| macOS    | `LOCAL_PEERPID` (SOL_LOCAL=0, opt=0x002)       | PID; uid via `getuid()` (same-user socket) |
| Windows  | Named Pipe (`\\.\pipe\cora-<user>`) + `GetNamedPipeClientProcessId` | PID, binary path via `QueryFullProcessImageNameW(OpenProcess(pid))` |

Binary path resolved per OS:
- Linux: `readlink /proc/<pid>/exe`
- macOS: `proc_pidpath(pid, ...)` (extern from libproc)
- Windows: `QueryFullProcessImageNameW(OpenProcess(peer_pid))` against the PID resolved by `GetNamedPipeClientProcessId`

Matched against `Policy.allowed_callers` from decrypted `cora.zon` config block.
Empty `allowed_callers` = dev-mode allow-all.

### `cr exec` Stdio Passing

The daemon detaches its own stdio to `/dev/null` / `NUL` after
daemonization, so a child spawned naively from the service inherits
that and silently drops its output. Each platform passes the caller's
real stdin/stdout/stderr through the IPC channel into the child:

| Platform | Mechanism |
| -------- | --------- |
| Linux/macOS | `sendmsg` with `SOL_SOCKET / SCM_RIGHTS` carrying the three fd values; service `recvmsg`s the cmsg and plumbs the fds into `std.process.spawn` as `.file` StdIo. |
| Windows | Client ships `GetStdHandle(STD_INPUT/OUTPUT/ERROR_HANDLE)` values as a 24-byte little-endian prefix on the spawn payload. Service uses `OpenProcess(PROCESS_DUP_HANDLE, GetNamedPipeClientProcessId(pipe))` + `DuplicateHandle` 3× to pull copies into its own process, then `CreateProcessW(bInheritHandles=TRUE)` with `STARTUPINFOW.hStdInput/Output/Error`. |

Result: `cr exec t -- echo hello` prints "hello" to the operator's
terminal on every supported platform. argv[0] is resolved to an
absolute path against the daemon's `PATH` (Linux/macOS `:` separator,
Windows `;` with `PATHEXT` extension lookup) before the
`Task.allowed_targets` check, and argv[0] is rewritten to the resolved
path so the spawn cannot drift to a different binary.

### Protocol (UDS, length-framed)

Frame: `[u8 version][u8 op][u32 LE payload_len][payload]`

Ops (`src/service/proto.zig`):
- `0x01 ping`
- `0x02 status` → 13-byte `StatusResp { running, secrets_count, idle_remaining_ms }`
- `0x03 lock`
- `0x04 task_declare` (payload = task name)
- `0x05 spawn` (payload = task name + argv list) → 8-byte `SpawnResp { child_pid, exit_code }`
- `0x7f err`

---

## Project Structure (as shipped)

```
cora/
├── CLAUDE.md                 ← you are here
├── README.md                 ← public face
├── SECURITY.md               ← threat model + responsible disclosure
├── LICENSE                   ← AGPL-3.0
├── build.zig
├── build.zig.zon             ← deps: vaxis 0.6.0
├── src/
│   ├── main.zig              ← CLI dispatch
│   ├── root.zig              ← library root + test aggregator
│   ├── error.zig             ← CoraError set
│   ├── audit.zig             ← Event union + JSONL Logger
│   ├── crypto/
│   │   ├── secret_buf.zig    ← SecretBuf — 512B stack buf, secureZero, no format method
│   │   ├── derive.zig        ← Argon2id key derivation
│   │   └── aead.zig          ← XChaCha20-Poly1305 wrapper
│   ├── store/
│   │   ├── format.zig        ← cora.zon binary header + layout
│   │   ├── store.zig         ← read/write/encrypt/decrypt + loadSecrets/saveSecrets
│   │   ├── secrets_codec.zig ← JSON {K:v} ↔ MemStore
│   │   └── mem.zig           ← MemStore — name → SecretBuf hashmap, zero on overwrite/delete
│   ├── service/
│   │   ├── proto.zig         ← framed IPC protocol
│   │   ├── idle.zig          ← atomic IdleTimer on Io.Timestamp (.awake clock)
│   │   ├── service.zig       ← accept loop, op dispatch, handleSpawn
│   │   └── client.zig        ← Conn + isRunning/status/lock/exec
│   ├── identity/
│   │   ├── identity.zig      ← CallerIdentity + per-OS dispatch
│   │   ├── linux.zig         ← SO_PEERCRED + /proc/<pid>/exe
│   │   ├── macos.zig         ← LOCAL_PEERPID + proc_pidpath
│   │   └── windows.zig       ← Tier 1: GetNamedPipeClientProcessId + QueryFullProcessImageNameW
│   ├── policy/
│   │   └── policy.zig        ← Policy { allowed_callers, idle_timeout_ms, tasks } via std.zon
│   └── tui/
│       └── menu.zig          ← vaxis pane-based UI (dashboard / audit / secrets / lock + modals)
└── tests/                    ← embedded as `test` blocks per file
```

Audit log lives at `~/.cora/audit.jsonl` (created on first `cr unlock`).

---

## Config Format

`cora.zon` — encrypted file, lives in cwd by default (or pass path to `cr init`).

**Header** (plaintext): `"CORA"` magic + `u8 version` + `[16]u8 salt` + `[24]u8 nonce`
**Config block** (plaintext): ZON-serialized `Policy` struct
**Secrets block** (encrypted): XChaCha20-Poly1305 ciphertext + 16B Poly1305 tag

Plaintext shape of `Policy` (what `cr policy show` reveals):

```zig
.{
    .allowed_callers = .{
        "/usr/local/bin/cr",
        "/usr/local/bin/claude",
    },
    .idle_timeout_ms = 900000,
    .tasks = .{
        .{ .name = "claude-task", .allowed_secrets = .{ "ANTHROPIC_API_KEY" } },
    },
}
```

Decrypted secrets block (never on disk in this form):

```json
{"ANTHROPIC_API_KEY":"sk-ant-...","GITHUB_TOKEN":"ghp_..."}
```

Managed by `cr secrets set/list/delete`. Never hand-edited.

---

## CLI Interface (`cr`) — every shipped subcommand

```bash
# Versioning / help
cr version
cr                                       # prints usage

# Setup
cr init [path]                           # default: ./cora.zon

# Secret management (always re-encrypts)
cr secrets set KEY                       # prompts passphrase + value
cr secrets list                          # prompts passphrase → names only
cr secrets delete KEY                    # prompts passphrase

# Policy (re-encrypts on each mutation)
cr policy show                           # callers + idle + tasks
cr policy allow PATH                     # add binary to allowed_callers
cr policy deny PATH                      # remove
cr policy task add NAME SECRETS...       # define/update task
cr policy task remove NAME

# Service lifecycle
cr unlock [--foreground]                 # daemonizes by default
cr lock                                  # sends lock op → service zeros + exits
cr status                                # running? secrets count? idle remaining

# Agent invocation (the whole point)
cr exec TASK -- argv...                  # spawn subprocess with task's secrets

# Audit
cr audit tail [-n N]                     # last N JSONL lines (default 20)
cr audit show [--task NAME]              # full log, optional filter

# Debug
cr verify --pid PID                      # resolve binary path for a pid

# Interactive
cr tui                                   # vaxis pane-based UI
```

---

## TUI (vaxis 0.6.0)

Current `cr tui` = full vaxis pane-based UI in `src/tui/menu.zig` (~700 LOC).
Views: dashboard / audit / secrets / lock. Modals: confirm-lock, passphrase
(masked). Keyboard-driven navigation between panes.

Run path is isolated — `cr exec` and `cr unlock` do **not** depend on the vaxis
render layer, so secrets-handling code stays decoupled from the TUI binary
surface.

---

## Memory Safety Model

```zig
pub const SecretBuf = struct {
    buf: [max_secret_len]u8 = undefined, // 512 bytes, stack-allocated
    len: usize = 0,

    pub fn set(self: *SecretBuf, value: []const u8) CoraError!void { ... }
    pub fn slice(self: *SecretBuf) []u8 { ... }
    pub fn constSlice(self: *const SecretBuf) []const u8 { ... }

    pub fn zero(self: *SecretBuf) void {
        std.crypto.secureZero(u8, &self.buf); // not optimized away
        self.len = 0;
    }
};

// Always:
var secret = SecretBuf{};
defer secret.zero(); // first line, every time, no exceptions

// Key derivation buffer — same rule
var key: [32]u8 = undefined;
defer std.crypto.secureZero(u8, &key);
try derive.deriveKey(&key, passphrase, &salt, allocator, io);
```

No GC. No hidden allocator. `defer` is explicit, readable, auditable.
`std.crypto.secureZero` (added in 0.16) is guaranteed not to be elided.

---

## Development Guidelines for Claude Code

1. **`defer secret.zero()` is the first line** after any `SecretBuf` init. No exceptions.
2. **Key derivation buffers also zeroed** — `defer std.crypto.secureZero(u8, &key)` always.
3. **Never log secret values** — `SecretBuf` has no `format` method (test asserts this). Compile error if attempted.
4. **`cora.zon` secrets block is never written plaintext** — `store.saveSecrets` always re-encrypts.
5. **Passphrase never stored** — used to derive key, then zeroed. Key lives only in service memory while unlocked.
6. **Platform identity code in `identity/`** — `identity.zig` dispatches; per-OS files stay isolated.
7. **TUI is separate compilation unit** — `cr exec` and `cr unlock` paths do not depend on vaxis-rendered widgets.
8. **Audit log: no secret values, ever** — `audit.Event` variants have no `value` field structurally; tests + e2e grep confirm.
9. **Policy validated at unlock time** — invalid config = hard fail before decryption attempted.
10. **`cr unlock` is the only entry point to decrypted state** — no other command keeps secrets in memory after returning.

### Zig 0.16 dialect notes (lessons from M0–M7)

- `pub fn main(init: std.process.Init) !void` — args via `init.minimal.args.toSlice(arena)`, io via `init.io`.
- `std.heap.GeneralPurposeAllocator` → `std.heap.DebugAllocator`.
- `std.fs.cwd()` → `std.Io.Dir.cwd()`; all `Dir`/`File` ops take `io: Io` first.
- `std.crypto.random` removed → `io.random(buffer)`.
- `std.posix.fork`/`socket` removed → `std.c.fork`, `std.Io.net.UnixAddress`.
- `std.time.sleep`/`milliTimestamp`/`nanoTimestamp` removed → `io.sleep(duration, clock)`, `Io.Timestamp.now(io, .real|.awake).toMilliseconds()`.
- `std.posix.getenv` removed → `std.c.getenv` + `std.mem.span`.
- `std.process.spawn(io, opts)` is now top-level (not `Child.spawn`); `Child.Term` variants are lowercase (`.exited`/`.signal`/`.stopped`/`.unknown`).
- `Environ.Map` (note capital E) for child env injection.
- `Io.Mutex` requires `io` to lock; for single-thread service paths we skip it entirely.
- ZON parsing via `std.zon.parse.fromSliceAlloc(T, gpa, source_sentinel, null, opts)`.

---

## Future: Transport Plugins

OS keychain, 1Password, Infisical, Vault — these are future community plugins.

Plugin interface will allow importing secrets FROM these sources INTO `cora.zon` (encrypted), or syncing. Core Cora will never depend on any external service at runtime.

---

## Competitive Positioning

|                   | Cora                   | HashiCorp Vault |
| ----------------- | ---------------------- | --------------- |
| Language          | **Zig**                | Go              |
| Secret storage    | **Encrypted file**     | Cloud/local     |
| Portable          | **Yes — one file**     | No              |
| Memory zeroing    | **`secureZero`**       | GC              |
| Caller verified   | **OS kernel**          | Nothing         |
| Infra required    | **None**               | None            |
| Single binary     | **Yes**                | No              |
| Interactive TUI   | **Yes (pane-based)**   | No              |
| Agent gets value? | **Never**              | Depends         |
| MCP server        | **No — by design**     | No              |
