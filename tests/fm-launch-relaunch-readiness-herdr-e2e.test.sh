#!/usr/bin/env bash
# Real-Herdr regression: a relaunch into the pane a departed agent left behind
# is allowed, while a shell that is genuinely not reading is still refused.
#
# The shell-readiness gate (bin/fm-launch-send-lib.sh rule 1) refuses a pane
# that renders but never runs its probe, because that is the wedge that used to
# swallow a launch command whole. A REUSED pane reaches that gate holding input
# nobody consumed: the interrupt key the control plane typed at the agent went
# into a foreground process that does not read stdin, and the pane's shell picks
# it up the moment that process exits. On Herdr the stray byte is then read as
# the introducer of the bracketed-paste sequence the client wraps around the
# next line, so the probe arrives as literal `[200~...~` text, never runs, and a
# shell that is reading perfectly well is refused - which is what broke the
# control smoke lane. The corruption is a property of what the vendor writes
# into the pane, so no stub can prove it; that is why this guard exists beside
# the portable one in tests/fm-spawn-launch-send.test.sh.
#
# The refusal is asserted at the gate rather than through a refused spawn,
# because on herdr 0.9.1 `agent get` answers an agent-free pane with
# agent_status "unknown" instead of `agent_not_found`, so a spawn against a
# long-running foreground process stops earlier, at the recovery classifier, on
# an unrelated defect.
#
# No harness is launched: the replacement is an inert script named like one, so
# this guard spends no model tokens.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

herdr_forget_inherited_pane
fm_live_gate default-on FM_LAUNCH_RELAUNCH_READINESS_E2E herdr jq git

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: live: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

HERDR_VERSION=$(herdr --version 2>&1 | head -1)
HERDR_VERSION=${HERDR_VERSION#herdr }
version_fail() { # <message>
  fail "$1 [herdr $HERDR_VERSION]"
}

HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(fm_test_tmproot fm-launch-relaunch-readiness)
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
PROJ="$TMP_ROOT/proj"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$PROJ"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-launch-relaunch-ready)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH

cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

# Every herdr call fm-spawn makes is routed through the lab helper, which is the
# only place the trailing --session is added, so the spawn under test can never
# reach the captain's default session.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

# The replacement "agent": an inert script that records that it started.
LAUNCH_MARK="$TMP_ROOT/codex-launched"
cat > "$FAKEBIN/codex" <<SH
#!/usr/bin/env bash
: > "$LAUNCH_MARK"
SH
chmod +x "$FAKEBIN/codex"

git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial

# One task per arm, each with its own worktree and its own real Herdr pane.
WSID=$(lab workspace create --cwd "$PROJ" --label fm-relaunch-ready --no-focus 2>/dev/null \
  | jq -r '.result.workspace.workspace_id // empty')
[ -n "$WSID" ] || fail "could not create the lab workspace"

setup_task() { # <task-id>  -> echoes the pane id
  local id=$1 wt created pane tab
  wt="$TMP_ROOT/wt-$id"
  git -C "$PROJ" worktree add --quiet -b "$id" "$wt"
  mkdir -p "$HOME_DIR/data/$id"
  cat > "$HOME_DIR/data/$id/brief.md" <<'BRIEF'
# Task
## Captain's intent
Exercise the relaunch readiness gate safely.

## Firstmate spec
Keep the isolated endpoint and worktree intact.
BRIEF
  created=$(lab tab create --workspace "$WSID" --cwd "$wt" --label "fm-$id" --no-focus 2>/dev/null) || return 1
  pane=$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id // empty')
  tab=$(printf '%s' "$created" | jq -r '.result.tab.tab_id // empty')
  [ -n "$pane" ] && [ -n "$tab" ] || return 1
  {
    echo "window=$HERDR_LAB_SESSION:$pane"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$PROJ"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "backend=herdr"
    echo "herdr_session=$HERDR_LAB_SESSION"
    echo "herdr_workspace_id=$WSID"
    echo "herdr_tab_id=$tab"
    echo "herdr_pane_id=$pane"
  } > "$HOME_DIR/state/$id.meta"
  printf '%s' "$pane"
}

# Put the inert replacement on the PANE's own PATH: the launch runs in that
# shell, not in this one.
seed_pane_path() { # <pane>
  local quoted
  printf -v quoted '%q' "$FAKEBIN"
  lab pane run "$1" "export PATH=$quoted:\$PATH" >/dev/null 2>&1
}

new_pane() { # <label>  -> echoes the pane id
  local pane
  pane=$(lab tab create --workspace "$WSID" --cwd "$PROJ" --label "fm-gate-$1" --no-focus 2>/dev/null \
    | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$pane" ] || return 1
  printf '%s' "$pane"
}

wait_for_prompt() { # <pane>
  local pane=$1 i=0
  while [ "$i" -lt 100 ]; do
    case "$(lab pane read "$pane" --source recent --lines 200 2>/dev/null)" in
    *[![:space:]]*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Leave the interrupt key pending in the pane's line editor exactly the way a
# departed agent does: type it at a foreground process that does not read
# stdin, then let that process exit.
leave_pending_interrupt() { # <pane>
  local pane=$1
  lab pane run "$pane" 'sleep 3' >/dev/null 2>&1 || return 1
  sleep 1
  lab pane send-keys "$pane" escape >/dev/null 2>&1 || return 1
  sleep 4
}

relaunch() { # <task-id>
  env PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" FM_HOME="$HOME_DIR" \
    HERDR_SESSION="$HERDR_LAB_SESSION" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$1" --relaunch --harness codex 2>&1
}

# --- the gate itself, against real Herdr panes ------------------------------
#
# Driven through the adapter channels fm-spawn.sh hands the library, so the
# verdicts come from what the real client actually writes into a real pane.

gate_verdict() { # <pane> <reset:0|1>  -> echoes the verdict
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" bash -c '
    set -u
    . "$1/bin/backends/herdr.sh"
    . "$1/bin/fm-launch-send-lib.sh"
    TARGET="$2:$3"
    send_line() { fm_backend_herdr_send_text_line "$TARGET" "$1"; }
    capture() { fm_backend_herdr_capture "$TARGET" 200 2>/dev/null || true; }
    send_key() { fm_backend_herdr_send_key "$TARGET" "$1"; }
    if [ "$4" = 1 ]; then
      fm_launch_reset_pane_input send_key || { printf reset-failed; exit 0; }
    fi
    verdict=0
    fm_launch_wait_shell_ready send_line capture 12 0.25 || verdict=$?
    printf "%s" "$verdict"
  ' _ "$ROOT" "$HERDR_LAB_SESSION" "$1" "$2"
}

# Two panes rather than one, because the mangled probe consumes the stray key
# itself: a second probe on the same pane would pass with no reset at all and
# prove nothing about the reset.
PANE_LEFTOVER=$(new_pane leftover) || fail "could not create the leftover-key pane"
wait_for_prompt "$PANE_LEFTOVER" || version_fail "the leftover-key pane never rendered a prompt"
leave_pending_interrupt "$PANE_LEFTOVER" \
  || version_fail "could not leave an unconsumed interrupt key in the pane"
VERDICT=$(gate_verdict "$PANE_LEFTOVER" 0)
[ "$VERDICT" = 1 ] \
  || version_fail "a pane holding an unconsumed interrupt key should mangle the probe and refuse, got verdict '$VERDICT'; the reset case below would prove nothing"
pass "real herdr $HERDR_VERSION: an unconsumed interrupt key makes the readiness probe fail"

PANE_CLEARED=$(new_pane cleared) || fail "could not create the reset pane"
wait_for_prompt "$PANE_CLEARED" || version_fail "the reset pane never rendered a prompt"
leave_pending_interrupt "$PANE_CLEARED" \
  || version_fail "could not leave an unconsumed interrupt key in the pane"
VERDICT=$(gate_verdict "$PANE_CLEARED" 1)
[ "$VERDICT" = 0 ] \
  || version_fail "the same pane shape must confirm readiness once its input is reset, got verdict '$VERDICT'"
pass "real herdr $HERDR_VERSION: the input reset clears the stray key and readiness is confirmed"

# The refusal the gate exists for must survive the reset: this shell ignores the
# interrupt outright and never returns to reading.
PANE_STUCK=$(new_pane stuck) || fail "could not create the stuck pane"
wait_for_prompt "$PANE_STUCK" || version_fail "the stuck pane never rendered a prompt"
lab pane run "$PANE_STUCK" "trap '' INT; sleep 600" >/dev/null 2>&1 \
  || fail "could not put the stuck pane's shell into an uninterruptible wait"
sleep 2
VERDICT=$(gate_verdict "$PANE_STUCK" 1)
[ "$VERDICT" = 1 ] \
  || version_fail "a shell that ignores the reset and never reads must still refuse, got verdict '$VERDICT'"
pass "real herdr $HERDR_VERSION: the input reset does not rescue a shell that is not reading"

# --- and the whole relaunch path, end to end --------------------------------

PANE_OK=$(setup_task relaunchable) || fail "could not create the relaunchable task's pane"
wait_for_prompt "$PANE_OK" || version_fail "the relaunchable task's pane never rendered a prompt"
seed_pane_path "$PANE_OK" || fail "could not put the inert replacement on the pane's PATH"
sleep 0.5
leave_pending_interrupt "$PANE_OK" \
  || version_fail "could not leave an unconsumed interrupt key in the pane"

OUT=$(relaunch relaunchable) \
  || version_fail "a pane holding an interrupt key its departed agent never read should still be relaunched: $OUT"
i=0
while [ "$i" -lt 60 ]; do
  [ ! -e "$LAUNCH_MARK" ] || break
  sleep 0.2
  i=$((i + 1))
done
[ -e "$LAUNCH_MARK" ] \
  || version_fail "the replacement was reported launched but never ran, so the typed line did not survive the pane: $OUT"
[ "$(sed -n 's/^window=//p' "$HOME_DIR/state/relaunchable.meta" | tail -1)" = "$HERDR_LAB_SESSION:$PANE_OK" ] \
  || fail "the relaunch replaced its endpoint instead of reusing it"
lab pane get "$PANE_OK" >/dev/null 2>&1 \
  || fail "the relaunch removed the endpoint it was required to reuse"
pass "real herdr $HERDR_VERSION: a relaunch into a pane holding an unconsumed interrupt key delivers its launch"

echo "all launch relaunch-readiness checks passed"
