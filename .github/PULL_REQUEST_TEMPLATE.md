<!--
PR title MUST follow Conventional Commits — CI will reject otherwise.
See CONTRIBUTING.md → "Commit conventions" for the type/scope/format rules.

Examples:
  feat(audit): add log rotation by size
  fix(crypto): zero key on Argon2id failure path
  feat(proto)!: bump frame header to v2          (breaking change)
  security: tighten LOCAL_PEERPID TOCTOU window
  docs(readme): document install.sh --channel flag
-->

## Summary

<!-- One or two sentences: what changes and why. -->

## Related issues

<!-- e.g. "Closes #123" or "Refs #45". Leave blank if standalone. -->

## OS impact

Cora cuts one upstream version per release, then fans out per-OS
mirror tags (`cora-macos-v*`, `cora-linux-v*`, `cora-windows-v*`) only
for the OSes whose files changed. Tick the OS(s) this PR affects so
reviewers can sanity-check the mirror-tag classifier:

- [ ] macOS — touches `src/identity/macos.zig` or shared code
- [ ] Linux — touches `src/identity/linux.zig` or shared code
- [ ] Windows — touches `src/identity/windows.zig`,
      `src/service/pipe_windows.zig`, `src/service/spawn_windows.zig`,
      or shared code

Anything outside `src/identity/{macos,linux,windows}.zig` and the
two `src/service/*_windows.zig` files is considered shared, so all
three OSes will get a mirror tag. Pure docs / template / CHANGELOG-only
diffs don't trigger any mirror — release-please still bumps the
version, but nothing is rebuilt.

To force a specific version use the plain-semver `Release-As: X.Y.Z`
footer; the mirror-tag step will still scope per-OS as above. See
[CONTRIBUTING.md → Releasing](../CONTRIBUTING.md#releasing-maintainers-only)
for the full rules.

## Changes

<!-- Short bullet list of the user-visible changes in this PR. -->

-
-

## Testing

<!-- How did you verify this works? Include commands or test names. -->

- [ ] `zig build test` passes locally (51/51 or higher).
- [ ] `zig build fmt` passes locally.
- [ ] Added or updated tests for the new behavior (or explained why not below).

<!-- If e2e testing was needed (service, exec, daemon flow), describe the
     manual steps you ran. -->

## Security checklist

Required for any change that touches `crypto/`, `store/`, `service/`,
`identity/`, `policy/`, or `audit.zig`. Tick each item or write N/A
with a one-line justification.

- [ ] `defer secret.zero()` is the first line after any new `SecretBuf` init.
- [ ] `defer std.crypto.secureZero(u8, &key)` after any new key derivation buffer.
- [ ] `SecretBuf` still has no `format` method.
- [ ] No new code path writes plaintext secrets to disk.
- [ ] Passphrase still derives → zeros, never persisted.
- [ ] No `value` / `secret_value` field added to any `audit.Event` variant.
- [ ] New error paths still let `defer` run (no `unreachable` / `@panic`
      before zeroing).
- [ ] Platform identity changes reviewed for TOCTOU.
- [ ] No new dependency surfacing plaintext secrets.

## Documentation

- [ ] User-visible CLI / protocol changes reflected in `README.md` and `CLAUDE.md`.
- [ ] Breaking changes flagged with `!` in PR title or `BREAKING CHANGE:` footer.

## Anything else?

<!-- Risks, follow-ups, screenshots, deployment notes. -->
