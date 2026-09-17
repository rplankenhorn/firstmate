# FM_CONFIG_OVERRIDE isolation — reproduction & fix evidence

## Root cause (bin/fm-spawn.sh)
- Line 420: `CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"` — `:-` treats an
  EMPTY value the same as unset, so `FM_CONFIG_OVERRIDE=''` falls back to the
  code root's own `config/`.
- Line 1284: when `$CONFIG/crew-dispatch.json` exists, batch/single dispatch
  aborts with `error: config/crew-dispatch.json is active ...` instead of
  reaching the intended missing-brief path the tests assert.

## Reproduction (same batch invocation the test drives)
Poisoned config (mimics operator's gitignored config/crew-dispatch.json), which
is what an EMPTY override resolves to on a machine whose real config has it:

    === OLD BEHAVIOR: FM_CONFIG_OVERRIDE points at config with crew-dispatch.json ===
    error: config/crew-dispatch.json is active - pass an explicit harness resolved
    from the dispatch rules ...
    EXIT=1
    # test assertion `grep -F 'batch: FAILED to spawn nope-batch-a-z1'` FAILS

Isolated empty config dir (the fix, FM_CONFIG_OVERRIDE="$CFG_DIR"):

    === FIXED BEHAVIOR: isolated empty config dir ===
    batch: FAILED to spawn nope-batch-a-z1 (projects/none-a)
    batch: FAILED to spawn nope-batch-b-z2 (projects/none-b)
    EXIT=1
    # exactly the output the intent predicts and the test asserts

## Test runs (target commit a590305)
- `bash tests/fm-spawn-batch.test.sh` -> EXIT=0, all 5 cases ok.
- 3 modified fm-backend.test.sh cases driven standalone -> all ok:
    ok - fm-spawn.sh --backend bogus is refused loudly
    ok - fm-spawn.sh --backend codex-app is refused
    ok - fm-spawn.sh honors FM_BACKEND and refuses an unimplemented value loudly

## Note
`tests/fm-backend.test.sh` full-suite run aborts earlier on
`test_spawn_symlinked_project_prefix_avoids_false_refusal` (line 1159), an
UNCHANGED test that fails from host env only: `mise ... config.toml not trusted`
and Claude workspace-trust pre-registration failing. Not caused by this change;
the modified cases run after it and pass when driven directly.
