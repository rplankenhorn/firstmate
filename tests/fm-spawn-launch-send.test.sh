#!/usr/bin/env bash
# tests/fm-spawn-launch-send.test.sh - regression for bin/fm-launch-send-lib.sh,
# the queue-safe launch-command delivery bin/fm-spawn.sh types into a worker
# pane. Uses a REAL tmux server on a private socket (`-L`) and real shells; it
# never launches an agent, so it spends no model tokens and runs wherever CI has
# tmux.
#
# The bug it pins: a pane whose foreground process is not reading input silently
# discards everything past its pseudo-terminal's input queue, so a long launch
# command arrives cut mid-string and no agent is ever created. The loss case
# below is asserted directly, so a future change that makes the pane forgiving
# cannot leave the fix case passing vacuously.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-launch-send-$$"
SHIM_DIR=

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}
trap cleanup_all EXIT

SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-launch-send.XXXXXX")
cat >"$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"
# shellcheck source=bin/fm-launch-send-lib.sh
. "$ROOT/bin/fm-launch-send-lib.sh"

# --- the split rule ----------------------------------------------------------

payload_ascii=$(printf 'A%.0s' $(seq 1 8000))
fm_launch_chunks_var "$payload_ascii" 512
[ "${#FM_LAUNCH_CHUNKS[@]}" -eq 16 ] ||
  fail "8000 bytes at 512 should split into 16 writes, got ${#FM_LAUNCH_CHUNKS[@]}"
joined=$(printf '%s' "${FM_LAUNCH_CHUNKS[@]}")
[ "$joined" = "$payload_ascii" ] || fail "split then rejoin lost or reordered bytes"
for chunk in "${FM_LAUNCH_CHUNKS[@]}"; do
  [ "$(printf '%s' "$chunk" | wc -c)" -le 512 ] || fail "a write exceeded the 512-byte bound"
done
pass "fm_launch_chunks_var splits to the bound and rejoins byte-for-byte"

# The bound is BYTES, not characters: a multibyte path in a launch command must
# not turn a 512-character slice into a write several times the queue. The euro
# sign is three bytes and 512 is not a multiple of three, so a naive byte split
# would sever a character at every chunk boundary; each write must still be valid
# UTF-8 on its own, because every backend decodes its own write.
valid_utf8() { printf '%s' "$1" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; }
command -v iconv >/dev/null 2>&1 || fail "iconv is required to check per-write UTF-8 validity"
payload_utf8=$(printf '\xe2\x82\xac%.0s' $(seq 1 1000))
fm_launch_chunks_var "$payload_utf8" 512
[ "${#FM_LAUNCH_CHUNKS[@]}" -gt 1 ] ||
  fail "a 3000-byte multibyte payload must split into more than one write"
for chunk in "${FM_LAUNCH_CHUNKS[@]}"; do
  [ "$(printf '%s' "$chunk" | wc -c)" -le 512 ] ||
    fail "a multibyte write exceeded the 512-byte bound"
  valid_utf8 "$chunk" ||
    fail "a multibyte write ended mid-character and is not valid UTF-8 on its own"
done
joined=$(printf '%s' "${FM_LAUNCH_CHUNKS[@]}")
[ "$joined" = "$payload_utf8" ] || fail "multibyte split then rejoin changed the text"
pass "fm_launch_chunks_var bounds writes in bytes without severing a character"

# shellcheck disable=SC2034  # read by fm_launch_chunk_size in this same shell
FM_LAUNCH_SEND_CHUNK=notanumber
[ "$(fm_launch_chunk_size)" = 512 ] || fail "a malformed chunk override should fall back to 512"
FM_LAUNCH_SEND_CHUNK=0
[ "$(fm_launch_chunk_size)" = 512 ] || fail "a zero chunk override should fall back to 512"
# shellcheck disable=SC2034  # read by fm_launch_chunk_size in this same shell
FM_LAUNCH_SEND_CHUNK=99999
[ "$(fm_launch_chunk_size)" = 1024 ] || fail "an oversized chunk override should cap at 1024"
unset FM_LAUNCH_SEND_CHUNK
pass "fm_launch_chunk_size refuses a malformed or oversized override"

# --- real panes --------------------------------------------------------------

tmux new-session -d -s t -x 200 -y 50 'sleep 600' ||
  fail "could not start the private tmux server"

# A window whose foreground process does not read input for <hold> seconds, then
# hands the terminal to an interactive shell. That is the shape of a freshly
# created pane whose shell is still running its startup files.
open_busy_window() { # <name> <hold>
  tmux new-window -d -n "$1" "sleep $2; exec bash --norc --noprofile -i" ||
    fail "could not create window $1"
}

# Ask the pane's shell how many bytes of the assignment actually reached it.
received_length() { # <target> <var>
  local target=$1 var=$2 out i=0
  fm_backend_tmux_send_text_line "$target" "printf 'FMLEN''=%s\\n' \"\${#$var}\""
  while [ "$i" -lt 100 ]; do
    out=$(fm_backend_tmux_capture "$target" 400 2>/dev/null || true)
    case "$out" in
    *FMLEN=*)
      printf '%s\n' "$out" | tr -d '\n' | sed -e 's/.*FMLEN=//' -e 's/[^0-9].*//'
      return 0
      ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# The loss case. One write of 8000 bytes into a pane that is not reading. Both
# supported platforms bound the queue well below that (1024 bytes on macOS,
# 4096 on Linux), so the tail is discarded with no error to the writer.
# Enter is held back until the shell is up, because the discard applies to it
# too: in the real bug the shell is left holding a truncated, unsubmitted line.
open_busy_window loss 2
fm_backend_tmux_send_literal 't:loss' "x=$payload_ascii"
sleep 4
fm_backend_tmux_send_key 't:loss' Enter
lost_len=$(received_length 't:loss' x) || fail "the loss pane never answered"
[ -n "$lost_len" ] || fail "could not read the loss pane's received length"
[ "$lost_len" -lt 8000 ] ||
  fail "expected a pane that is not reading to discard the tail, but all 8000 bytes arrived"
pass "a single long write into a pane that is not reading loses its tail ($lost_len of 8000 bytes)"

# The fix. Same pane shape, but wait for the shell to prove it is reading and
# executing, then write in queue-safe pieces.
open_busy_window fixed 2
send_line_fixed() { fm_backend_tmux_send_text_line 't:fixed' "$1"; }
capture_fixed() { fm_backend_tmux_capture 't:fixed' 400 2>/dev/null || true; }
send_literal_fixed() { fm_backend_tmux_send_literal 't:fixed' "$1"; }

fm_launch_wait_shell_ready send_line_fixed capture_fixed 120 0.25 ||
  fail "the readiness probe never came back from a pane whose shell does start"
fm_launch_send_literal_chunked send_literal_fixed "y=$payload_ascii" 512 0.05 ||
  fail "the chunked write reported a failure"
[ "${#FM_LAUNCH_CHUNKS[@]}" -gt 1 ] ||
  fail "the fix case must exercise more than one write or it proves nothing about chunking"
fm_backend_tmux_send_key 't:fixed' Enter
fixed_len=$(received_length 't:fixed' y) || fail "the fixed pane never answered"
[ "$fixed_len" = 8000 ] ||
  fail "expected all 8000 bytes after the readiness gate, got $fixed_len"
pass "readiness gate plus chunked writes deliver all 8000 bytes to the same pane shape"

# --- the file rule ------------------------------------------------------------

# The record itself: the command must come back byte-for-byte, and the file must
# not be readable by anyone else at any point, because it carries the worker's
# whole system prompt and brief pointer.
cmd_file="$SHIM_DIR/launch-command"
fm_launch_command_file "$cmd_file" "z=$payload_ascii" ||
  fail "fm_launch_command_file reported a failure"
[ "$(cat "$cmd_file")" = "z=$payload_ascii" ] ||
  fail "the recorded launch command did not come back byte-for-byte"
# BSD stat first, GNU stat second: both supported platforms answer one of them.
mode=$(stat -f '%OLp' "$cmd_file" 2>/dev/null || stat -c '%a' "$cmd_file")
[ "$mode" = 600 ] ||
  fail "the recorded launch command must be private to its owner, got mode $mode"
# A nested destination is created rather than refused, so a caller is free to
# keep the record beside the task's other state.
fm_launch_command_file "$SHIM_DIR/nested/dir/launch-command" 'x=1' ||
  fail "fm_launch_command_file should create a missing destination directory"
pass "fm_launch_command_file records the command privately and byte-for-byte"

# The typed line. It must stay short no matter how long the command is, and a
# path that cannot be single-quoted is refused rather than emitted as a line
# that would come apart in the pane.
source_line=$(fm_launch_source_line "$cmd_file") ||
  fail "fm_launch_source_line refused an ordinary path"
[ "$(printf '%s' "$source_line" | wc -c)" -lt 1024 ] ||
  fail "the typed line must stay under the smallest supported input queue"
fm_launch_source_line "/tmp/it's/a/path" >/dev/null 2>&1 &&
  fail "a path containing a single quote must be refused, not quoted badly"
pass "fm_launch_source_line stays short and refuses an unquotable path"

# End to end: the same pane shape that loses the tail of one long write receives
# the whole 8000-byte command when only the source line is typed. This is the
# rule that removes the hazard rather than narrowing it - the typed line does
# not grow with the command.
open_busy_window sourced 2
send_line_sourced() { fm_backend_tmux_send_text_line 't:sourced' "$1"; }
capture_sourced() { fm_backend_tmux_capture 't:sourced' 400 2>/dev/null || true; }
send_literal_sourced() { fm_backend_tmux_send_literal 't:sourced' "$1"; }

fm_launch_wait_shell_ready send_line_sourced capture_sourced 120 0.25 ||
  fail "the readiness probe never came back from the sourcing pane"
fm_launch_send_literal_chunked send_literal_sourced "$source_line" 512 0.05 ||
  fail "writing the source line reported a failure"
fm_backend_tmux_send_key 't:sourced' Enter
sourced_len=$(received_length 't:sourced' z) || fail "the sourcing pane never answered"
[ "$sourced_len" = 8000 ] ||
  fail "expected all 8000 bytes of the recorded command, got $sourced_len"
pass "a short source line delivers an 8000-byte command the pane would have truncated"

# Verdict 1, the wedge: a pane that renders text but never reads input. This is
# the case a caller must refuse, because a shell is demonstrably there and is
# demonstrably not executing what was typed.
tmux new-window -d -n wedged "printf 'PANE IS RENDERING\\n'; sleep 600" ||
  fail "could not create the wedged window"
send_line_wedged() { fm_backend_tmux_send_text_line 't:wedged' "$1"; }
capture_wedged() { fm_backend_tmux_capture 't:wedged' 400 2>/dev/null || true; }
i=0
while [ "$i" -lt 100 ]; do
  case "$(capture_wedged)" in
  *'PANE IS RENDERING'*) break ;;
  esac
  sleep 0.1
  i=$((i + 1))
done
case "$(capture_wedged)" in
*'PANE IS RENDERING'*) ;;
*) fail "the wedged pane never rendered, so the verdict-1 case would be vacuous" ;;
esac
verdict=0
fm_launch_wait_shell_ready send_line_wedged capture_wedged 4 0.1 || verdict=$?
[ "$verdict" = 1 ] ||
  fail "a rendering pane that never runs the probe must give verdict 1, got $verdict"
pass "fm_launch_wait_shell_ready refuses a pane that renders but never executes"

# Verdict 2, no observability: a capture that yields nothing is not evidence
# about a shell, and must be reported apart from the wedge above.
send_line_blind() { :; }
capture_blind() { printf ''; }
verdict=0
fm_launch_wait_shell_ready send_line_blind capture_blind 2 0.05 || verdict=$?
[ "$verdict" = 2 ] ||
  fail "a pane with no readable output must give verdict 2, got $verdict"
# A capture of blank rows is still no ink, so it must not be mistaken for the
# wedge; an empty pane is spaces and newlines, not an empty string.
capture_blank_rows() { printf '   \n   \n'; }
verdict=0
fm_launch_wait_shell_ready send_line_blind capture_blank_rows 2 0.05 || verdict=$?
[ "$verdict" = 2 ] ||
  fail "a blank-but-present capture must give verdict 2, got $verdict"
pass "fm_launch_wait_shell_ready separates no readable output from a wedge"

# The blank bound. A pane that has shown nothing at all has no shell that could
# still be starting, so reaching verdict 2 must not cost the whole budget. A
# pane that IS rendering keeps every poll, because elapsed time is the only
# thing that tells an ordinary slow prompt from a wedged shell.
blank_count="$SHIM_DIR/blank-polls"
printf '0\n' >"$blank_count"
capture_counting_blank() {
  printf '%s\n' "$(($(cat "$blank_count") + 1))" >"$blank_count"
  printf ''
}
verdict=0
FM_LAUNCH_READY_BLANK_POLLS=3 \
  fm_launch_wait_shell_ready send_line_blind capture_counting_blank 60 0.01 || verdict=$?
[ "$verdict" = 2 ] ||
  fail "a pane with no readable output must still give verdict 2, got $verdict"
[ "$(cat "$blank_count")" = 3 ] ||
  fail "the blank bound must end the wait after 3 polls, took $(cat "$blank_count")"

ink_count="$SHIM_DIR/ink-polls"
printf '0\n' >"$ink_count"
capture_counting_ink() {
  printf '%s\n' "$(($(cat "$ink_count") + 1))" >"$ink_count"
  printf 'PROMPT\n'
}
verdict=0
FM_LAUNCH_READY_BLANK_POLLS=3 \
  fm_launch_wait_shell_ready send_line_blind capture_counting_ink 12 0.01 || verdict=$?
[ "$verdict" = 1 ] ||
  fail "a rendering pane that never runs the probe must still give verdict 1, got $verdict"
[ "$(cat "$ink_count")" = 12 ] ||
  fail "a rendering pane must keep the whole budget, took $(cat "$ink_count") of 12 polls"
pass "the blank bound shortens only the pane that shows nothing"

# --- the reset a reused pane needs -------------------------------------------
#
# The relaunch case the three-valued verdict was never meant to catch. A pane
# whose agent has exited can still be holding input nobody consumed: the
# interrupt key the control plane typed at the agent went into a foreground
# process that does not read stdin, and the shell picks it up when that process
# exits. The stray byte then corrupts whatever is typed next - on tmux it is
# read as the start of a key binding, on a backend that wraps its writes in
# bracketed paste it eats the sequence's own introducer - so the probe never
# runs and a shell that is reading perfectly well is refused. Two panes are
# used rather than one because the mangled probe consumes the stray byte
# itself: a second probe on the same pane would pass without any reset and
# prove nothing.
open_shell_window() { # <name>
  tmux new-window -d -n "$1" 'exec bash --norc --noprofile -i' ||
    fail "could not create window $1"
  local i=0
  while [ "$i" -lt 100 ]; do
    case "$(fm_backend_tmux_capture "t:$1" 400 2>/dev/null || true)" in
    *[![:space:]]*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  fail "window $1 never rendered a prompt"
}

# Leave the interrupt key pending in <name>'s line editor the way a departed
# agent does: type it at a foreground process that does not read stdin, then
# let that process exit.
leave_pending_key() { # <name>
  fm_backend_tmux_send_text_line "t:$1" 'sleep 2'
  sleep 0.5
  fm_backend_tmux_send_key "t:$1" Escape
  sleep 3
}

open_shell_window leftover
send_leftover() { fm_backend_tmux_send_text_line 't:leftover' "$1"; }
capture_leftover() { fm_backend_tmux_capture 't:leftover' 400 2>/dev/null || true; }
leave_pending_key leftover
verdict=0
fm_launch_wait_shell_ready send_leftover capture_leftover 12 0.25 || verdict=$?
[ "$verdict" = 1 ] ||
  fail "a pane holding an unconsumed interrupt key should mangle the probe and give verdict 1, got $verdict; the reset case below would prove nothing"
pass "an unconsumed interrupt key in a reused pane makes the readiness probe fail"

open_shell_window cleared
send_cleared() { fm_backend_tmux_send_text_line 't:cleared' "$1"; }
capture_cleared() { fm_backend_tmux_capture 't:cleared' 400 2>/dev/null || true; }
send_key_cleared() { fm_backend_tmux_send_key 't:cleared' "$1"; }
leave_pending_key cleared
fm_launch_reset_pane_input send_key_cleared ||
  fail "fm_launch_reset_pane_input reported a failure on a live pane"
verdict=0
fm_launch_wait_shell_ready send_cleared capture_cleared 12 0.25 || verdict=$?
[ "$verdict" = 0 ] ||
  fail "the same pane shape must confirm readiness once its input is reset, got verdict $verdict"
pass "fm_launch_reset_pane_input clears the stray key and the same pane confirms readiness"

# The reset must not turn the wedge into a pass. This shell ignores the
# interrupt outright and never returns to reading, which is the condition the
# refusal exists for, so it must still reach verdict 1 after being reset.
open_shell_window stuck
send_stuck() { fm_backend_tmux_send_text_line 't:stuck' "$1"; }
capture_stuck() { fm_backend_tmux_capture 't:stuck' 400 2>/dev/null || true; }
send_key_stuck() { fm_backend_tmux_send_key 't:stuck' "$1"; }
fm_backend_tmux_send_text_line 't:stuck' "trap '' INT; sleep 600"
sleep 1
fm_launch_reset_pane_input send_key_stuck ||
  fail "fm_launch_reset_pane_input reported a failure on the stuck pane"
verdict=0
fm_launch_wait_shell_ready send_stuck capture_stuck 8 0.25 || verdict=$?
[ "$verdict" = 1 ] ||
  fail "a shell that ignores the reset and never reads must still give verdict 1, got $verdict"
pass "the input reset does not rescue a shell that is genuinely not reading"

echo "all launch-send checks passed"
