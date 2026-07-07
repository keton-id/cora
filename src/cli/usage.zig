//! Central source of truth for `cr` CLI help text and argument-flag matching.
//!
//! Every `print*` function writes a pre-baked usage block to either stdout or
//! stderr based on the `Channel` argument. Stdout is used when the user
//! explicitly requests help (`cr help`, `cr --help`, `cr <sub> --help`).
//! Stderr is used when usage is printed as part of an error path (unknown
//! subcommand, missing argument). This matches POSIX conventions and keeps
//! `cr --help | grep foo` pipe-friendly.
//!
//! All help text lives here, not in `main.zig`, so the top-level usage table
//! and per-subcommand help cannot drift apart silently.

const std = @import("std");
const Io = std.Io;

pub const Channel = enum { stdout, stderr };

/// Recognize the help flag in the three forms most CLIs accept.
/// Used both at the top level (`cr --help`) and per-subcommand
/// (`cr secrets --help`, `cr policy task --help`).
pub fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or
        std.mem.eql(u8, arg, "-h") or
        std.mem.eql(u8, arg, "help");
}

/// Recognize the version flag. `cr version` is handled separately as a
/// legacy subcommand; this matches only the flag forms `--version` / `-V`.
pub fn isVersionFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--version") or
        std.mem.eql(u8, arg, "-V");
}

fn write(io: Io, ch: Channel, text: []const u8) void {
    const f = switch (ch) {
        .stdout => Io.File.stdout(),
        .stderr => Io.File.stderr(),
    };
    f.writeStreamingAll(io, text) catch {};
}

/// Formatted write to stdout. Use this for *data* output (lists, dumps,
/// confirmation lines) that callers may want to pipe — `cr secrets list`,
/// `cr policy show`, `cr audit tail`, etc. Error / warning / prompt
/// messages should continue to use `std.debug.print` so they stay on
/// stderr.
///
/// Implementation mirrors the `write` helper above: format into a stack
/// buffer, then call `writeStreamingAll` on `Io.File.stdout()`. This is
/// the same code path the help-text writes already use, so behavior is
/// uniform across all supported platforms. The
/// `writerStreaming`/`interface.print`/`flush` triplet was tried first
/// but appeared to drop output on Windows when the child's stdout was a
/// pipe (CI regression on PR #25), so we stay with the proven path.
///
/// Fails open: a `bufPrint` overflow or a failed write silently drops
/// the line rather than propagating. This matches `std.debug.print`'s
/// behavior and avoids turning a broken pipe into a process error.
/// The 16 KB stack buffer comfortably fits any single CLI line emitted
/// today (longest is an audit JSONL line, typically < 1 KB).
pub fn outPrint(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [16 * 1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    Io.File.stdout().writeStreamingAll(io, text) catch return;
}

// --- Top-level ------------------------------------------------------------

pub fn printTop(io: Io, ch: Channel) void {
    write(io, ch, top_text);
}

const top_text =
    \\cr — Cora secret runtime
    \\
    \\Usage:
    \\  cr <subcommand> [options]
    \\  cr help [<subcommand> [<action>]]
    \\  cr [--help | -h]
    \\  cr [--version | -V]
    \\
    \\Subcommands:
    \\  init [path]                          Create encrypted cora.zon
    \\  unlock [--foreground]                Start background service
    \\  lock                                 Stop service, zero memory
    \\  status                               Show service state
    \\  exec TASK -- argv...                 Spawn subprocess with task secrets injected
    \\  secrets <set|list|delete> [KEY]      Manage secrets
    \\  policy <show|allow|deny|task> ...    Manage policy
    \\  audit <tail|show> [opts]             Read audit log
    \\  tui                                  Launch interactive TUI menu
    \\  verify --pid PID                     Resolve binary path of a pid (debug)
    \\  version                              Show version
    \\
    \\Global options:
    \\  -h, --help                           Show help
    \\  -V, --version                        Show version
    \\
    \\Run `cr help <subcommand>` for details on a subcommand.
    \\
;

// --- init -----------------------------------------------------------------

pub fn printInit(io: Io, ch: Channel) void {
    write(io, ch, init_text);
}

const init_text =
    \\cr init — Create an encrypted cora.zon
    \\
    \\Usage:
    \\  cr init [path]
    \\
    \\Arguments:
    \\  path                                 Output path (default: cora.zon)
    \\
    \\Prompts for a passphrase (confirmed twice). The passphrase derives an
    \\Argon2id key that encrypts the secrets block. The resulting file is
    \\portable — copy it anywhere; the passphrase is the only key.
    \\
    \\Refuses to overwrite an existing file at `path`.
    \\
;

// --- unlock ---------------------------------------------------------------

pub fn printUnlock(io: Io, ch: Channel) void {
    write(io, ch, unlock_text);
}

const unlock_text =
    \\cr unlock — Start the background service
    \\
    \\Usage:
    \\  cr unlock [--foreground]
    \\
    \\Options:
    \\  --foreground                         Stay in foreground (do not daemonize)
    \\
    \\Prompts for the passphrase, decrypts the secrets block into memory,
    \\and listens on the per-user IPC endpoint for requests. By default
    \\the process daemonizes:
    \\  POSIX:   fork + setsid + redirect stdio to /dev/null
    \\  Windows: re-execs itself with `--foreground` via CreateProcessW
    \\           and DETACHED_PROCESS, piping the passphrase in once.
    \\With `--foreground`, the process stays attached to the terminal —
    \\useful for debugging or running under a supervisor.
    \\
;

// --- lock -----------------------------------------------------------------

pub fn printLock(io: Io, ch: Channel) void {
    write(io, ch, lock_text);
}

const lock_text =
    \\cr lock — Stop the service and zero secret memory
    \\
    \\Usage:
    \\  cr lock
    \\
    \\Sends a lock op to the running service. The service zeros every
    \\SecretBuf via std.crypto.secureZero, unlinks the UDS, and exits.
    \\Disk state is unchanged (still encrypted).
    \\
    \\Errors with exit 1 if no service is running.
    \\
;

// --- status ---------------------------------------------------------------

pub fn printStatus(io: Io, ch: Channel) void {
    write(io, ch, status_text);
}

const status_text =
    \\cr status — Show service state
    \\
    \\Usage:
    \\  cr status
    \\
    \\Prints whether the service is running, the number of secrets held in
    \\memory, and the idle-timeout remaining. Output is uniform across
    \\macOS, Linux, and Windows — see SECURITY.md for the per-OS trust
    \\model.
    \\
;

// --- exec -----------------------------------------------------------------

pub fn printExec(io: Io, ch: Channel) void {
    write(io, ch, exec_text);
}

const exec_text =
    \\cr exec — Spawn a subprocess with task secrets injected
    \\
    \\Usage:
    \\  cr exec TASK -- argv...
    \\
    \\Arguments:
    \\  TASK                                 Task name defined in the policy
    \\  argv...                              Command and arguments to execute
    \\
    \\Asks the running service to verify the caller, look up TASK in the
    \\policy, fetch the task's allowed secrets, and spawn `argv` with those
    \\secrets injected into the child's environment. The agent process
    \\itself never sees the values.
    \\
    \\Exits with the child's exit code (masked to the low byte).
    \\
;

// --- audit ----------------------------------------------------------------

pub fn printAudit(io: Io, ch: Channel) void {
    write(io, ch, audit_text);
}

const audit_text =
    \\cr audit — Read the audit log
    \\
    \\Usage:
    \\  cr audit <tail|show> [options]
    \\
    \\Actions:
    \\  tail [-n N]                          Show the last N entries (default 20)
    \\  show [--task NAME]                   Show the full log, optionally filtered
    \\
    \\The audit log is JSONL at ~/.cora/audit.jsonl. Entries never include
    \\secret values (see audit.Event variants for the schema).
    \\
    \\Run `cr help audit <action>` for action-specific details.
    \\
;

pub fn printAuditTail(io: Io, ch: Channel) void {
    write(io, ch, audit_tail_text);
}

const audit_tail_text =
    \\cr audit tail — Show the most recent audit entries
    \\
    \\Usage:
    \\  cr audit tail [-n N]
    \\
    \\Options:
    \\  -n N                                 Number of entries (default 20)
    \\
;

pub fn printAuditShow(io: Io, ch: Channel) void {
    write(io, ch, audit_show_text);
}

const audit_show_text =
    \\cr audit show — Show the full audit log
    \\
    \\Usage:
    \\  cr audit show [--task NAME]
    \\
    \\Options:
    \\  --task NAME                          Only show entries for the given task
    \\
;

// --- tui ------------------------------------------------------------------

pub fn printTui(io: Io, ch: Channel) void {
    write(io, ch, tui_text);
}

const tui_text =
    \\cr tui — Launch the interactive TUI
    \\
    \\Usage:
    \\  cr tui
    \\
    \\Opens the vaxis-based pane UI with dashboard, audit, secrets, and
    \\lock views. Use the keyboard to navigate between panes. The TUI is a
    \\separate compilation unit and does not affect the `cr exec` /
    \\`cr unlock` codepaths.
    \\
;

// --- verify ---------------------------------------------------------------

pub fn printVerify(io: Io, ch: Channel) void {
    write(io, ch, verify_text);
}

const verify_text =
    \\cr verify — Resolve the binary path of a pid (debug)
    \\
    \\Usage:
    \\  cr verify --pid PID
    \\
    \\Options:
    \\  --pid PID                            Pid to look up
    \\
    \\Uses the platform identity module to resolve the executable behind
    \\the given pid:
    \\  Linux:   readlink /proc/<pid>/exe
    \\  macOS:   proc_pidpath(pid, ...)
    \\  Windows: QueryFullProcessImageNameW(OpenProcess(pid))
    \\
;

// --- secrets --------------------------------------------------------------

pub fn printSecrets(io: Io, ch: Channel) void {
    write(io, ch, secrets_text);
}

const secrets_text =
    \\cr secrets — Manage secrets in cora.zon
    \\
    \\Usage:
    \\  cr secrets <set|list|delete> [KEY]
    \\
    \\Actions:
    \\  set KEY                              Add or update a secret (prompts for value)
    \\  list                                 List secret names (no values)
    \\  delete KEY                           Remove a secret
    \\
    \\Each action prompts for the passphrase, decrypts cora.zon, mutates,
    \\and re-encrypts. The on-disk file is never written in plaintext.
    \\
    \\If the service is running, in-memory secrets are not updated by
    \\these commands — run `cr lock && cr unlock` for changes to take
    \\effect in the running service.
    \\
    \\Run `cr help secrets <action>` for action-specific details.
    \\
;

pub fn printSecretsSet(io: Io, ch: Channel) void {
    write(io, ch, secrets_set_text);
}

const secrets_set_text =
    \\cr secrets set — Add or update a secret
    \\
    \\Usage:
    \\  cr secrets set KEY
    \\
    \\Arguments:
    \\  KEY                                  Secret name (env var name)
    \\
    \\Prompts for the passphrase, then for the secret value (echo masked).
    \\
;

pub fn printSecretsList(io: Io, ch: Channel) void {
    write(io, ch, secrets_list_text);
}

const secrets_list_text =
    \\cr secrets list — List secret names
    \\
    \\Usage:
    \\  cr secrets list
    \\
    \\Prints one secret name per line. Values are never printed.
    \\
    \\When the service is unlocked, the names are fetched from the
    \\running process and no passphrase is prompted. When the service is
    \\locked, the vault is decrypted from disk and the passphrase is
    \\required.
    \\
;

pub fn printSecretsDelete(io: Io, ch: Channel) void {
    write(io, ch, secrets_delete_text);
}

const secrets_delete_text =
    \\cr secrets delete — Remove a secret
    \\
    \\Usage:
    \\  cr secrets delete KEY
    \\
    \\Arguments:
    \\  KEY                                  Secret name to remove
    \\
;

// --- policy ---------------------------------------------------------------

pub fn printPolicy(io: Io, ch: Channel) void {
    write(io, ch, policy_text);
}

const policy_text =
    \\cr policy — Manage the access policy in cora.zon
    \\
    \\Usage:
    \\  cr policy <show|allow|deny|task> ...
    \\
    \\Actions:
    \\  show                                 Print callers, idle timeout, tasks
    \\  allow PATH                           Add a binary to allowed_callers
    \\  deny PATH                            Remove a binary from allowed_callers
    \\  task <add|remove> NAME [SECRETS...]  Manage task definitions
    \\
    \\Each mutating action prompts for the passphrase and re-encrypts the
    \\file. As with `cr secrets`, running-service state is not refreshed —
    \\lock and unlock to apply.
    \\
    \\Run `cr help policy <action>` for action-specific details.
    \\
;

pub fn printPolicyShow(io: Io, ch: Channel) void {
    write(io, ch, policy_show_text);
}

const policy_show_text =
    \\cr policy show — Print the current policy
    \\
    \\Usage:
    \\  cr policy show
    \\
    \\Output includes idle_timeout_ms, the allowed_callers list, and
    \\every task definition with its allowed secrets.
    \\
    \\When the service is unlocked, the summary is fetched from the
    \\running process and no passphrase is prompted. When the service is
    \\locked, the vault is decrypted from disk and the passphrase is
    \\required.
    \\
;

pub fn printPolicyAllow(io: Io, ch: Channel) void {
    write(io, ch, policy_allow_text);
}

const policy_allow_text =
    \\cr policy allow — Add a binary to allowed_callers
    \\
    \\Usage:
    \\  cr policy allow PATH [--pin]
    \\
    \\Arguments:
    \\  PATH                                 Absolute path of the caller binary
    \\
    \\Flags:
    \\  --pin                                Pin the caller to the current
    \\                                       SHA-256 of PATH. A swapped binary
    \\                                       at the same path is then rejected.
    \\
    \\If allowed_callers is empty, the policy is in dev-mode (allow-all).
    \\Adding any entry switches to explicit allow-list mode.
    \\
;

pub fn printPolicyDeny(io: Io, ch: Channel) void {
    write(io, ch, policy_deny_text);
}

const policy_deny_text =
    \\cr policy deny — Remove a binary from allowed_callers
    \\
    \\Usage:
    \\  cr policy deny PATH
    \\
    \\Arguments:
    \\  PATH                                 Path to remove
    \\
;

pub fn printPolicyTask(io: Io, ch: Channel) void {
    write(io, ch, policy_task_text);
}

const policy_task_text =
    \\cr policy task — Manage task definitions
    \\
    \\Usage:
    \\  cr policy task <add|remove> NAME [SECRETS...]
    \\
    \\Actions:
    \\  add NAME [SECRETS...]                Define or replace a task
    \\  remove NAME                          Remove a task
    \\
    \\A task scopes which secrets `cr exec TASK -- argv...` may inject.
    \\Adding a task with the same name replaces the previous definition.
    \\
;

pub fn printPolicyTaskAdd(io: Io, ch: Channel) void {
    write(io, ch, policy_task_add_text);
}

const policy_task_add_text =
    \\cr policy task add — Define a task
    \\
    \\Usage:
    \\  cr policy task add NAME [--target PATH ...] [--max-spawns N]
    \\                    [--window-ms MS] [SECRETS...]
    \\
    \\Arguments:
    \\  NAME                                 Task name
    \\  SECRETS...                           Allowed secret names (zero or more)
    \\
    \\Options:
    \\  --target PATH                        Absolute path of a binary that
    \\                                       may be the spawn target (argv[0])
    \\                                       for this task. Repeatable. If
    \\                                       omitted entirely, any binary is
    \\                                       allowed (dev mode) — same
    \\                                       behavior as allowed_callers when
    \\                                       its list is empty.
    \\  --max-spawns N                       Cap spawns per window (0 = no
    \\                                       limit, default). Bounds how often
    \\                                       this task's secrets can be pulled
    \\                                       into a subprocess.
    \\  --window-ms MS                       Rate-limit window in ms
    \\                                       (default 60000). Used with
    \\                                       --max-spawns.
    \\
    \\Replaces any existing task with the same name.
    \\
    \\Without --target, a trusted caller can still leak a secret value by
    \\spawning `/bin/echo $TOKEN`, `/bin/cat /proc/self/environ`, or
    \\`/usr/bin/printenv`. Listing the binaries the task is actually meant
    \\to drive closes that hole. Example:
    \\
    \\  cr policy task add github --target /usr/bin/gh GH_TOKEN
    \\
;

pub fn printPolicyTaskRemove(io: Io, ch: Channel) void {
    write(io, ch, policy_task_remove_text);
}

const policy_task_remove_text =
    \\cr policy task remove — Remove a task
    \\
    \\Usage:
    \\  cr policy task remove NAME
    \\
    \\Arguments:
    \\  NAME                                 Task name to remove
    \\
;

// --- tests ----------------------------------------------------------------

test "isHelpFlag accepts the three standard forms" {
    try std.testing.expect(isHelpFlag("--help"));
    try std.testing.expect(isHelpFlag("-h"));
    try std.testing.expect(isHelpFlag("help"));
    try std.testing.expect(!isHelpFlag("--Help"));
    try std.testing.expect(!isHelpFlag("h"));
    try std.testing.expect(!isHelpFlag(""));
    try std.testing.expect(!isHelpFlag("init"));
}

test "isVersionFlag accepts the two standard forms" {
    try std.testing.expect(isVersionFlag("--version"));
    try std.testing.expect(isVersionFlag("-V"));
    try std.testing.expect(!isVersionFlag("-v"));
    try std.testing.expect(!isVersionFlag("version"));
    try std.testing.expect(!isVersionFlag(""));
}
