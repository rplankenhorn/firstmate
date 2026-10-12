# Firstmate upstream reconciliation

Date: 2026-10-12

## Review branch and source state

The local review branch is `reconcile/firstmate-upstream-20261012`.

| Reference | Commit |
| --- | --- |
| `origin/main` after fetch | `41a3cccdaba7036477cb40b912afce10ef5f0ca1` |
| `upstream/main` after fetch | `20dcbf91520b1816663b81873ad67d0b93b3e4d6` |
| feature tip used as branch base | `029245852ca61d80122aed6b607bc492d5d68b4b` |
| merge commit | `e9950bba` |

The branch was created from the feature tip and merged with
`upstream/main` using a non-fast-forward merge. `main`, other local branches,
and both remotes were left unchanged.

## Eleven-commit relevance assessment

The first nine rows are the fork-main commits in chronological order. The last
two are the additional commits on
`chore/fix-contribution-observer-account-selection`.

| Commit | Change | Decision | Reason |
| --- | --- | --- | --- |
| `17f87043` | Isolate `FM_CONFIG_OVERRIDE` in the spawn-batch fixture | **retained** | Shared test isolation; it does not depend on OpenCode. |
| `df73365b` | Arm the OpenCode primary watcher from shared supervision need | **dropped** | Fork-only OpenCode implementation and its tests were removed. The upstream OpenCode plugin and behavior are unchanged. |
| `5662248e` | Make Codex supervision satisfiable at its turn boundary | **adapted** | The Codex checkpoint model, fresh/stale beacon handling, and strict mid-turn supervision were retained and reconciled with upstream recovery behavior. |
| `5abd3b6d` | Refresh the watcher beacon and bound Herdr CLI calls | **adapted** | Beacon refresh was retained; Herdr calls use the reconciled per-client execution/reaping path from the later Linux fix and upstream adapter changes. |
| `81ff7908` | Document `FM_HERDR_CLI_TIMEOUT` | **retained** | The public configuration catalog now describes the retained timeout knob. |
| `73a4a881` | Document wedged-watcher restart repair | **retained** | The Codex checkpoint recovery guidance remains valid and matches the retained implementation. |
| `e8c74acd` | Cover public stale-lock recovery through reconcile | **retained** | Shared stale-lock recovery regression remains applicable after the upstream merge. |
| `a23e34e5` | Scope the Herdr CLI timeout | **adapted** | Timeout documentation was kept and checked against the merged Herdr backend, including the long-lived server exception. |
| `41a3cccd` | Isolate harness-specific watcher fixtures | **adapted** | Shared Claude/Codex ancestry isolation was retained; the fork-only OpenCode fixture was removed. |
| `5e86423c` | Omit ambient GitHub token from registered contribution checks | **retained** | Registered checks remain scoped with `env -u GITHUB_TOKEN`; manual polling continues to use the ambient token when explicitly requested. |
| `02924585` | Fix Linux killed-read ancestry, Herdr process cleanup, and contribution behavior | **adapted** | The `/proc` ancestry fixture and Herdr process-group cleanup were retained alongside upstream changes; contribution credential/manual-poll behavior was preserved. |

## Resulting behavior

- OpenCode implementation, tests, and documentation are identical to
  `upstream/main`.
- Codex keeps checkpoint supervision: a fresh foreground checkpoint beacon is
  accepted at the turn boundary, while a stale beacon without a live watcher
  remains a failure. A wedged watcher produces restart-repair guidance.
- Herdr operational calls have bounded client timeouts and process-group
  cleanup. The long-lived `server` operation remains outside that timeout.
- Registered contribution checks do not inherit `GITHUB_TOKEN`; manual polling
  remains an explicit ambient-token path.

## Verification

The final targeted fixture command was:

```text
bin/fm-test-run.sh --jobs 1 --per-script-timeout-secs 1800 \
  tests/fm-session-start.test.sh \
  tests/fm-backend-herdr.test.sh \
  tests/fm-timeout-lib.test.sh
```

| Environment | Result |
| --- | --- |
| macOS | 3 passed, 0 failed. The two `/proc`-only killed-read checks were skipped because macOS has no readable `/proc`. |
| Ubuntu 24.04 container with `--init` and a non-root test user | 3 passed, 0 failed. The Linux `/proc` killed-read regression, hung-read cleanup, Herdr timeout, and descendant-reaping checks all ran. |

Additional focused macOS checks passed for Codex turn-end fresh/stale beacon
handling, checkpoint wedged-watcher repair, and the recovery loop. Changed
shell files passed `bash -n`, and `CI=true bin/fm-lint.sh` completed without
reported lint failures.

The broad `fm-procevent` suite and the aggregate watcher-lock run were not
used as final gates: they start or depend on live Lavish/listener processes.
The watcher-lock aggregate also hung in the shared stale-lock concurrency
case, so it was interrupted and is reported as unavailable rather than
treated as a passing result. The relevant retained recovery behavior is
covered by the targeted checkpoint, recovery-loop, session-start, and Linux
process-cleanup checks above.
