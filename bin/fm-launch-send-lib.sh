# shellcheck shell=bash
# Shared launch-command delivery for a freshly created worker pane.
# Usage: . bin/fm-launch-send-lib.sh
#        fm_launch_wait_shell_ready <send-line-fn> <capture-fn> [<polls>] [<interval>]
#        fm_launch_send_literal_chunked <send-literal-fn> <text> [<size>] [<pause>]
#        fm_launch_chunks_var <text> [<size>]   -> FM_LAUNCH_CHUNKS array
#
# ONE OWNER for the two rules that make a long launch command survive the trip
# into a pane shell. bin/fm-spawn.sh is the only production caller; the callbacks
# are injected so the rules can be exercised against a real pane with no harness
# and no spawn (tests/fm-spawn-launch-send.test.sh).
#
# WHY THIS EXISTS. A pane's pseudo-terminal holds a bounded queue of pending
# input - 1024 bytes on macOS - and the queue only drains while the foreground
# reader is actually reading. A shell that is still running its startup files has
# not entered its line editor yet, so nothing drains, the queue fills at 1024
# bytes, and every later byte is DISCARDED with no error to the writer. A launch
# command longer than that queue therefore arrives cut mid-string, the shell is
# left on a quote-continuation prompt, and no agent process is ever created.
# Measured 2026-09-17 on macOS 25.6.0 with tmux 3.6b: a 1073-byte claude launch
# command sent 0.3s after pane creation arrived as 1027 bytes, while the same
# 1073-byte string - and 2000- and 3000-byte strings - arrived intact once the
# pane's shell had settled. The cut is a property of the queue and the reader,
# not of the command, so it is backend-independent: every backend writes into the
# same pseudo-terminal.
#
# THE TWO RULES.
#  1. fm_launch_wait_shell_ready proves the pane shell is reading and executing
#     before anything long is typed. It is a round trip, not a rendered banner:
#     the probe line is a printf the shell must RUN to produce the marker, and
#     the typed text carries the marker in two pieces so the echoed command line
#     can never satisfy the match on its own.
#     Its verdict has three values, because "the shell did not run my probe" and
#     "this pane shows me nothing at all" are different facts and only the first
#     is evidence about a shell. 0 is confirmed. 1 means the pane rendered text
#     for the whole budget and still never produced the marker: a shell is there
#     and is not executing, which is exactly the wedge, so the caller must
#     refuse. 2 means no poll ever returned any pane text, so there is nothing
#     to judge - the same unreachable-evidence shape the model and quota probes
#     in bin/fm-spawn.sh already treat as a notice rather than a refusal.
#     A slow-starting shell is NOT case 2: it renders the moment it starts and
#     then runs the probe that was queued while it was busy, so it reaches 0.
#     Case 2 in practice means a backend that never ran a shell at all.
#  2. fm_launch_send_literal_chunked keeps any single write well under the
#     queue, so a shell that stops reading again mid-send - a slow prompt hook
#     firing between writes - cannot lose a tail either. This is defense in
#     depth behind rule 1, not a replacement for it: chunking alone cannot help
#     a shell that never drains.
#
# TUNING. FM_LAUNCH_SEND_CHUNK bounds one write in bytes (default 512, capped at
# 1024). FM_LAUNCH_SEND_PAUSE is the drain pause between writes.
# FM_LAUNCH_READY_POLLS and FM_LAUNCH_READY_INTERVAL bound the readiness wait,
# and the same two values are the optional fourth and fifth arguments so a
# caller that already owns a timeout policy is not forced through an env var.
# The suite sets a short budget once in tests/fixtures.sh: every fake backend
# there returns case 2, and waiting out the production budget for each of them
# would cost minutes of test time to learn nothing.

FM_LAUNCH_SEND_CHUNK_DEFAULT=512
FM_LAUNCH_SEND_CHUNK_MAX=1024
FM_LAUNCH_SEND_PAUSE_DEFAULT=0.05
FM_LAUNCH_READY_POLLS_DEFAULT=120
FM_LAUNCH_READY_INTERVAL_DEFAULT=0.25

# fm_launch_chunk_size: the validated per-write byte bound. A malformed or zero
# FM_LAUNCH_SEND_CHUNK falls back to the default rather than producing an empty
# or infinite split, and no override may exceed the queue it exists to respect.
fm_launch_chunk_size() {
  local size=${FM_LAUNCH_SEND_CHUNK:-$FM_LAUNCH_SEND_CHUNK_DEFAULT}
  case "$size" in
  '' | *[!0-9]* | 0) size=$FM_LAUNCH_SEND_CHUNK_DEFAULT ;;
  esac
  [ "$size" -le "$FM_LAUNCH_SEND_CHUNK_MAX" ] || size=$FM_LAUNCH_SEND_CHUNK_MAX
  printf '%s' "$size"
}

# fm_launch_chunks_var <text> [<size>]: split <text> into FM_LAUNCH_CHUNKS, each
# at most <size> BYTES. The local LC_ALL=C is what makes the bound bytes rather
# than characters: the queue counts bytes, so a multibyte path in the command
# must not let a 512-character slice become a 1500-byte write. The bound stays in
# bytes, but a chunk never ends mid UTF-8 sequence: if the byte just past the
# slice is a continuation byte (a partial character), the slice shrinks to the
# last complete character, so every backend that decodes its write on its own
# receives only whole characters.
fm_launch_chunks_var() {
  local LC_ALL=C
  local text=$1 size=${2:-} off=0 len tail ord
  [ -n "$size" ] || size=$(fm_launch_chunk_size)
  FM_LAUNCH_CHUNKS=()
  while [ "$off" -lt "${#text}" ]; do
    len=$size
    while [ "$((off + len))" -lt "${#text}" ]; do
      tail=${text:$((off + len)):1}
      ord=$(printf '%d' "'$tail")
      [ "$ord" -lt -64 ] || break
      len=$((len - 1))
      [ "$len" -gt 0 ] || { len=$size; break; }
    done
    FM_LAUNCH_CHUNKS+=("${text:off:len}")
    off=$((off + len))
  done
}

# fm_launch_wait_shell_ready <send-line-fn> <capture-fn> [<polls>] [<interval>]:
# 0 the pane shell executed a probe of our own making, 1 the pane rendered but
# never executed it, 2 the pane never rendered anything to judge. <send-line-fn>
# takes one command line and submits it; <capture-fn> prints the pane's current
# plain text. See the three-value verdict in the header for what a caller owes
# each value.
fm_launch_wait_shell_ready() {
  local send=$1 capture=$2
  local polls=${3:-${FM_LAUNCH_READY_POLLS:-$FM_LAUNCH_READY_POLLS_DEFAULT}}
  local interval=${4:-${FM_LAUNCH_READY_INTERVAL:-$FM_LAUNCH_READY_INTERVAL_DEFAULT}}
  local tail marker pane pane_ink i=0 rendered=0
  case "$polls" in '' | *[!0-9]* | 0) polls=$FM_LAUNCH_READY_POLLS_DEFAULT ;; esac
  # The marker is split across two printf arguments so the pane's echo of the
  # typed line cannot contain it; only the shell's own OUTPUT can.
  tail="READY_$$_${RANDOM}${RANDOM}"
  marker="FM_LAUNCH_$tail"
  "$send" "printf '%s%s\\n' 'FM_LAUNCH_' '$tail'" || return 2
  while [ "$i" -lt "$polls" ]; do
    pane=$("$capture" 2>/dev/null) || pane=
    case "$pane" in
    *"$marker"*) return 0 ;;
    esac
    # Any non-blank frame proves the pane has a rendering process behind it, so
    # a later exhausted budget is evidence about a shell rather than silence.
    # A blank-but-present capture (an empty pane is all spaces and newlines) is
    # not that evidence, so whitespace is stripped before the test.
    if [ "$rendered" = 0 ]; then
      pane_ink=${pane//[$' \t\r\n']/}
      [ -z "$pane_ink" ] || rendered=1
    fi
    i=$((i + 1))
    [ "$i" -ge "$polls" ] || sleep "$interval"
  done
  [ "$rendered" = 1 ] || return 2
  return 1
}

# fm_launch_send_literal_chunked <send-literal-fn> <text> [<size>] [<pause>]:
# type <text> into the pane in queue-safe pieces, pausing between writes so the
# reader can drain. <send-literal-fn> takes one string and types it without
# submitting. Returns the first write failure.
fm_launch_send_literal_chunked() {
  local send=$1 text=$2 size=${3:-} pause=${4:-}
  local chunk first=1
  [ -n "$pause" ] || pause=${FM_LAUNCH_SEND_PAUSE:-$FM_LAUNCH_SEND_PAUSE_DEFAULT}
  fm_launch_chunks_var "$text" "$size"
  [ "${#FM_LAUNCH_CHUNKS[@]}" -gt 0 ] || return 0
  for chunk in "${FM_LAUNCH_CHUNKS[@]}"; do
    [ "$first" = 1 ] || sleep "$pause"
    first=0
    "$send" "$chunk" || return 1
  done
}
