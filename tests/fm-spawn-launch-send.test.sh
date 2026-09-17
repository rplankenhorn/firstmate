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

echo "all launch-send checks passed"
