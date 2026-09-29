# Evidence: protect live Claude tests from the auto-updater

Change: bin/fm-spawn.sh embeds DISABLE_AUTOUPDATER into the claude launch;
tests/lib.sh fm_live_gate exports DISABLE_AUTOUPDATER=1 on proceed; three new
regression tests in tests/fm-live-gate.test.sh.

Note: this host's `node` is a mise shim (/usr/local/bin/node ->
~/.local/share/mise/shims/node). The spawn fixtures run fm-spawn under a
throwaway HOME, so mise cannot find its trust record and node aborts with
"Config files ... are not trusted", which made the claude-trust preregister
(and thus the spawn) fail. Fixed at invocation with
MISE_TRUSTED_CONFIG_PATHS=~/.config/mise/config.toml (no source change). This
is a real-usage non-issue: a real spawn runs under the operator's real HOME
where the config is trusted.

## 1. All live-gate tests pass (13/13), including the 3 new ones

$ MISE_TRUSTED_CONFIG_PATHS=~/.config/mise/config.toml bash tests/fm-live-gate.test.sh
ok - a proceeding live run exports DISABLE_AUTOUPDATER=1
ok - DISABLE_AUTOUPDATER rides fm-spawn's claude launch through to the harness pane
ok - DISABLE_AUTOUPDATER is embedded in the launch so a daemon-built pane keeps it
ok - all 38 live guards refuse together on FM_LIVE=0
EXIT=0

## 2. Regression proof - daemon-path test fails against BASE fm-spawn.sh

With bin/fm-spawn.sh reverted to base bf336a3 (no embed), the daemon pane that
strips DISABLE_AUTOUPDATER from its own env sees the updater ON:

not ok - fm-spawn must embed DISABLE_AUTOUPDATER in the launch command ... (missing: 'autoupdater=1')
autoupdater=unset

With the fix restored the same synthetic daemon pane sees autoupdater=1.
The test fails before the fix and passes after it.
